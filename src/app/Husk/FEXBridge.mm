/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Husk -- FEXCore probe (Madeira-lite M0).
 *
 * Structure and FEXCore call sequence follow Madeira's app/Madeira/FEXBridge.mm
 * (GPL-3.0-or-later + Madeira Converter Exception), which is the only known
 * working in-process FEXCore host on iOS. Two things are deliberately
 * different:
 *
 *   * The JIT region comes from husk-ios-jit.c (husk_ios_jit_allocate), not
 *     from a debugger RPC. On a jailbroken iOS 12.2 the allocator takes its
 *     "MAP_JIT"/"plain" route, so no StikDebug round trip is involved.
 *   * The guest program is a 12-byte blob that calls exit(42), not a linked
 *     ELF. That keeps the probe free of an ELF loader and a syscall table:
 *     translation, execution, the syscall exit hook and the longjmp out are
 *     the whole surface under test.
 *
 * A negative return means setup failed; husk_fex_last_error() says where.
 */
#include "FEXBridge.h"
#include "HuskWinSyscalls.h"
#include "WineProbe.h"   /* M6b: forward a guest syscall to wineserver */

// Xcode defines DEBUG=1, which collides with LogMan::DEBUG.
#ifdef DEBUG
#define HUSK_SAVED_DEBUG DEBUG
#undef DEBUG
#endif

#include "../../ios-jit/husk-ios-jit.h"

#include <FEXCore/Config/Config.h>
#include <FEXCore/Core/Context.h>
#include <FEXCore/Core/CoreState.h>
#include <FEXCore/Core/HostFeatures.h>
#include <FEXCore/Core/SignalDelegator.h>
#include <FEXCore/Debug/InternalThreadState.h>
#include <FEXCore/HLE/SyscallHandler.h>
#include <FEXCore/Utils/Allocator.h>
#include <FEXCore/Utils/AllocatorHooks.h>
#include <FEXCore/Utils/DualMap.h>
#include <FEXCore/Utils/LogManager.h>

#include <mach/mach.h>
#include <mach/vm_map.h>
// M7b: read back the protection mprotect() applied. The iOS SDK ships
// <mach/mach_vm.h> as a deliberately unsupported stub ("mach_vm.h
// unsupported"), so the 64-bit *vm_region* API from vm_region.h is the one
// that actually exists on this platform.
#include <mach/vm_region.h>
#include <sys/mman.h>
#include <libkern/OSCacheControl.h>

#include <atomic>
#include <csetjmp>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <unistd.h>

#ifdef HUSK_SAVED_DEBUG
#define DEBUG HUSK_SAVED_DEBUG
#undef HUSK_SAVED_DEBUG
#endif

// M5 reads the bundled PE image with pure C. ci_build.sh links this file
// against libFEXCore_all.a alone (-Wl,-undefined,error) as an early check, so
// NSBundle/NSData would pass the app link but fail that probe for missing
// Foundation/libobjc symbols. _NSGetExecutablePath is libSystem only.
#include <mach-o/dyld.h>

extern "C" void __clear_cache(void *start, void *end) {
    sys_icache_invalidate(start, static_cast<size_t>(
        static_cast<char *>(end) - static_cast<char *>(start)));
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
static char g_err[512];
static void set_err(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void set_err(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    vsnprintf(g_err, sizeof(g_err), fmt, ap);
    va_end(ap);
    fprintf(stderr, "[husk-fex] %s\n", g_err);
}

// Unbuffered progress trace. fprintf() output can be lost when the process
// dies from SIGBUS mid-JIT, which is exactly the failure mode M5 is chasing.
static void husk_pe_trace(const char *label, uint64_t a, uint64_t b) {
    char buf[192];
    int n = snprintf(buf, sizeof(buf), "[husk-pe] %s a=0x%llx b=0x%llx\n",
                     label, (unsigned long long)a, (unsigned long long)b);
    if (n > 0) (void)::write(2, buf, static_cast<size_t>(n));
}

static HuskDualMapping g_map{};
static uint8_t *g_rx = nullptr;
static size_t g_pool = 0;
static std::atomic<size_t> g_used{0};
static std::mutex g_lock;

static fextl::unique_ptr<FEXCore::Context::Context> g_ctx;
static std::atomic<bool> g_ready{false};
static std::atomic<int64_t> g_cached{-999};

static jmp_buf g_exit_jmp;
static int64_t g_exit_code = 0;

// ---- M6: Windows syscall dispatch state -----------------------------------
// Armed ONLY by husk_m6_probe(). A launch runs exactly one FEXCore guest
// program (a second guest thread SIGBUSes on iOS 12.2), so the flag belongs to
// whichever probe owns that guest; the M0/M5 Linux exit(60) path never sets it.
static bool g_win_mode = false;
static uint32_t g_win_seq = 0;   // Windows syscalls seen, in order
static uint32_t g_win_hits = 0;  // bit n set when expected call n matched

// M6b: only husk_m6b_probe() arms this. It routes one of the four guest
// Windows syscalls through the retained wineserver channel instead of
// answering locally, and the probe's verdict requires that round trip to
// succeed; M0/M5/M6a never set it.
static bool g_win_use_ws = false;
static bool g_ws_call_ok = false;

// Defined in the M6 section below (kept inside the strict-syntax fixture's
// slice, which starts at the M5 banner).
static uint64_t husk_win_dispatch(FEXCore::HLE::SyscallArguments *args);

// The guest code region the probe hands to FEX. The decoder asks the syscall
// handler whether an address is executable before decoding it
// (Frontend::CheckRangeExecutable -> QueryGuestExecutableRange), so this has to
// be reported or every block decodes as NOEXEC_INST and the thread dies.
static uint64_t g_code_base = 0;
static uint64_t g_code_size = 0;

// ---------------------------------------------------------------------------
// JIT region: exec allocations are carved out of the dual mapping
// ---------------------------------------------------------------------------
static void *fex_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off) {
    if ((prot & PROT_EXEC) && g_rx) {
        size_t a = (len + 0x3fff) & ~static_cast<size_t>(0x3fff);
        size_t o = g_used.fetch_add(a, std::memory_order_relaxed);
        if (o + a > g_pool) {
            set_err("FEX JIT pool exhausted (%zu+%zu > %zu)", o, a, g_pool);
            return MAP_FAILED;
        }
        return g_rx + o;
    }
    return ::mmap(addr, len, prot, flags, fd, off);
}

static int fex_munmap(void *addr, size_t len) {
    if (g_rx && addr >= static_cast<void *>(g_rx) &&
        addr < static_cast<void *>(g_rx + g_pool)) {
        return 0; // bump allocator: nothing to give back
    }
    return ::munmap(addr, len);
}

// ---------------------------------------------------------------------------
// Syscall handler: only exit(2) is needed, and it escapes via longjmp
// ---------------------------------------------------------------------------
class HuskSyscall final : public FEXCore::HLE::SyscallHandler {
public:
    // OS_LINUX64 is kept for BOTH probes. It is the only ABI for which the JIT
    // (a) fills SyscallArguments and (b) writes the handler's return value back
    // into guest RAX. OS_GENERIC deliberately spills everything and leaves the
    // argument array uninitialised, which would break the NTSTATUS contract.
    // Conveniently the Linux64 array is RAX,RDI,RSI,RDX,R10,R8,R9 -- it still
    // exposes R10/RDX/R8/R9, which is exactly where Windows x64 syscall
    // arguments live (Wine's stub begins with `mov r10,rcx` because the
    // syscall instruction overwrites RCX with the return RIP).
    HuskSyscall() { OSABI = FEXCore::HLE::SyscallOSABI::OS_LINUX64; }
    uint64_t HandleSyscall(FEXCore::Core::CpuStateFrame *, FEXCore::HLE::SyscallArguments *args) override {
        if (g_win_mode) return husk_win_dispatch(args);
        if (args->Argument[0] == 60) { // exit
            g_exit_code = static_cast<int64_t>(args->Argument[1]);
            longjmp(g_exit_jmp, 1);
        }
        set_err("unexpected guest syscall %llu", (unsigned long long)args->Argument[0]);
        g_exit_code = -2;
        longjmp(g_exit_jmp, 1);
    }

    // SyscallHandler has two more pure virtuals. The probe has no code cache
    // and no executable-file bookkeeping, so LookupExecutableFileSection is an
    // empty answer; QueryGuestExecutableRange must answer for the probe's own
    // code region or the x86 decoder refuses to decode it.
    FEXCore::HLE::ExecutableRangeInfo QueryGuestExecutableRange(
        FEXCore::Core::InternalThreadState *, uint64_t Address) override {
        if (g_code_base && Address >= g_code_base && Address < g_code_base + g_code_size) {
            return {g_code_base, g_code_size, false};
        }
        return {};
    }
    std::optional<FEXCore::ExecutableFileSectionInfo> LookupExecutableFileSection(
        FEXCore::Core::InternalThreadState *, uint64_t) override {
        return std::nullopt;
    }
};

class HuskSignals final : public FEXCore::SignalDelegator {};

static HuskSyscall g_syscall;
static HuskSignals g_signals;

static void fex_log_handler(LogMan::DebugLevels lvl, const char *msg) {
    fprintf(stderr, "[husk-fex:%s] %s\n", LogMan::DebugLevelStr(lvl), msg);
}
static void fex_throw_handler(const char *msg) {
    set_err("FEXCore throw: %s", msg);
}

// ---------------------------------------------------------------------------
// One-time FEXCore setup, shared by the M0 self-check and the M5 PE probe.
//
// M5 finding (2026-11-07): creating a SECOND guest thread on an already used
// Context is fatal on iOS 12.2. The second JIT code buffer's last page fails
// mprotect and the app dies with SIGBUS right after [TI-IC] jitcore-done;
// isolating the wineserver probe did not change it. Therefore exactly ONE
// guest program may run per app launch, and the two probes are gated by
// separate marker files (see LegacyRootViewController.swift).
// ---------------------------------------------------------------------------
static int64_t husk_fex_init(void) {
    // 1. dual-mapped JIT region from Husk's allocator. husk_ios_jit_allocate
    //    hands back the prewarmed region when it is big enough, otherwise it
    //    allocates one; the probe runs before QEMU, so this is the allocate path.
    HuskDualMapping m = husk_ios_jit_allocate(64u << 20);
    if (!m.rw_addr || !m.rx_addr) {
        set_err("no JIT region (husk_ios_jit_allocate failed; route=%s)",
                husk_ios_jit_self_route() ? husk_ios_jit_self_route() : "none");
        g_cached.store(-1);
        return -1;
    }
    g_map = m;
    g_rx = m.rx_addr;
    g_pool = m.size;
    g_used.store(0);

    // RW/RX distance. FEX writes through RW, executes through RX.
    FEXCore::DualMap::WriteOffset =
        reinterpret_cast<intptr_t>(m.rw_addr) - reinterpret_cast<intptr_t>(m.rx_addr);
    fprintf(stderr, "[husk-fex] JIT rx=%p rw=%p size=%zu offset=%lld\n",
            (void *)m.rx_addr, (void *)m.rw_addr, m.size,
            (long long)FEXCore::DualMap::WriteOffset);

    // 2. FEX allocator hooks
    FEXCore::Allocator::mmap = fex_mmap;
    FEXCore::Allocator::munmap = fex_munmap;

    LogMan::Msg::InstallHandler(fex_log_handler);
    LogMan::Throw::InstallHandler(fex_throw_handler);

    // 3. config
    try {
        FEXCore::Config::Initialize();
        FEXCore::Config::Set(FEXCore::Config::ConfigOption::CONFIG_IS64BIT_MODE, "1");
    } catch (...) {
        set_err("Config::Initialize threw");
        g_cached.store(-2);
        return -2;
    }

    // 4. host features -- Apple A12 (iPad8,1): ARMv8.3, LSE atomics, CRC,
    //    RCPC, no SVE.
    FEXCore::HostFeatures feat{};
    feat.DCacheLineSize = 128;
    feat.ICacheLineSize = 64;
    feat.SupportsCacheMaintenanceOps = true;
    feat.SupportsAES = true;
    feat.SupportsCRC = true;
    feat.SupportsAtomics = true;
    feat.SupportsRCPC = true;
    feat.SupportsTSOImm9 = true;
    feat.SupportsSHA = true;
    feat.SupportsPMULL_128Bit = true;
    feat.SupportsFCMA = true;
    feat.SupportsFlagM = true;
    feat.SupportsFlagM2 = true;
    feat.SupportsAVX = false;
    feat.SupportsSVE128 = false;
    feat.SupportsSVE256 = false;
    feat.CPUMIDRs.resize(6, 0x610F0220); // A12 Vortex/Tempest (approx)

    g_ctx = FEXCore::Context::Context::CreateNewContext(feat);
    if (!g_ctx) { set_err("CreateNewContext null"); g_cached.store(-3); return -3; }

    g_ctx->SetSignalDelegator(&g_signals);
    g_ctx->SetSyscallHandler(&g_syscall);
    g_ctx->SetHardwareTSOSupport(true);

    if (!g_ctx->InitCore()) { set_err("InitCore failed"); g_cached.store(-4); return -4; }
    return 0;
}

// ---------------------------------------------------------------------------
// M0 probe: the 53-byte FEXCore self-check (exit=42).
// ---------------------------------------------------------------------------
int64_t husk_fex_probe(void) {
    if (g_ready.load(std::memory_order_acquire)) return 0; // already ran
    if (g_cached.load() != -999) return g_cached.load();

    std::lock_guard<std::mutex> lock(g_lock);
    if (g_cached.load() != -999) return g_cached.load();

    const int64_t initrc = husk_fex_init();
    if (initrc != 0) { g_cached.store(initrc); return initrc; }

    // 5. guest code: a 53-byte self-checking program, hand-assembled from
    //    probe/probe.s in the workspace:
    //        sum = 1+2+...+1000            (loop, cmp/jle)
    //        if sum != 500500 -> exit(1)   (arithmetic + branch)
    //        else call get42; exit(eax)    (call/ret through the call-ret stack)
    //    Exit 42 therefore means the decoder, the JIT, the loop, the branch and
    //    the shadow call stack all agree with a real assembler's output.
    static const uint8_t blob[] = {
        0x31, 0xC0, 0xB9, 0x01, 0x00, 0x00, 0x00, 0x01, 0xC8, 0xFF, 0xC1,
        0x81, 0xF9, 0xE8, 0x03, 0x00, 0x00, 0x7E, 0xF4, 0x3D, 0x14, 0xA3,
        0x07, 0x00, 0x75, 0x09, 0xE8, 0x10, 0x00, 0x00, 0x00, 0x89, 0xC7,
        0xEB, 0x05, 0xBF, 0x01, 0x00, 0x00, 0x00, 0xB8, 0x3C, 0x00, 0x00,
        0x00, 0x0F, 0x05, 0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3,
    };
    constexpr size_t CODE_SIZE = 0x4000;
    void *code = ::mmap(nullptr, CODE_SIZE, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (code == MAP_FAILED) { set_err("code mmap failed"); g_cached.store(-5); return -5; }
    memcpy(code, blob, sizeof(blob));
    uint64_t code_addr = reinterpret_cast<uint64_t>(code);
    g_code_base = code_addr;
    g_code_size = CODE_SIZE;

    // 6. guest stack, laid out like a Linux static binary's initial stack
    constexpr size_t STACK_SIZE = 0x10000;
    void *stack = ::mmap(nullptr, STACK_SIZE, PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (stack == MAP_FAILED) { set_err("stack mmap failed"); g_cached.store(-6); return -6; }
    uint64_t sp_addr = reinterpret_cast<uint64_t>(stack) + STACK_SIZE;
    uint64_t *sp = reinterpret_cast<uint64_t *>(sp_addr);
    *(--sp) = 0; // AT_NULL value
    *(--sp) = 0; // AT_NULL type
    *(--sp) = 0; // envp[0]
    *(--sp) = 0; // argv[0]
    *(--sp) = 0; // argc
    uint64_t start_sp = reinterpret_cast<uint64_t>(sp);

    auto *thread = g_ctx->CreateThread(code_addr, start_sp);
    if (!thread) { set_err("CreateThread null"); g_cached.store(-7); return -7; }

    // call-ret shadow stack
    {
        constexpr size_t CR = FEXCore::Core::InternalThreadState::CALLRET_STACK_SIZE;
        constexpr size_t PG = 0x4000;
        void *a = ::mmap(nullptr, CR + 2 * PG, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (a == MAP_FAILED) { set_err("callret mmap failed"); g_cached.store(-8); return -8; }
        void *base = static_cast<uint8_t *>(a) + PG;
        ::mprotect(base, CR, PROT_READ | PROT_WRITE);
        thread->CallRetStackBase = base;
        thread->CurrentFrame->State.callret_sp = reinterpret_cast<uint64_t>(base) + CR / 4;
    }

    // minimal long-mode GDT, so the frontend decodes 64-bit code
    {
        static FEXCore::Core::CPUState::gdt_segment gdt[1] = {};
        gdt[0].L = 1; gdt[0].D = 0; gdt[0].P = 1; gdt[0].S = 1;
        gdt[0].Type = 0b1011;
        thread->CurrentFrame->State.segment_arrays[0] = gdt;
        thread->CurrentFrame->State.cs_idx = 0;
    }

    g_exit_code = -99;
    if (setjmp(g_exit_jmp) == 0) {
        g_ctx->ExecuteThread(thread);
        set_err("ExecuteThread returned without exit");
        g_exit_code = -9;
    }
    g_cached.store(g_exit_code);
    fprintf(stderr, "[husk-fex] probe exit=%lld (want 42)\n", (long long)g_exit_code);
    return g_exit_code;
}

const char *husk_fex_last_error(void) {
    return g_err[0] ? g_err : nullptr;
}

// ---------------------------------------------------------------------------
// M5: the first Windows PE
//
// Resources/hello.exe is a freestanding PE32+ produced by
// x86_64-w64-mingw32-gcc. Its entry point is literally
//
//     b8 2a 00 00 00   mov eax, 42
//     c3               ret
//
// No import is referenced on that path and there is no base relocation table,
// so loading it needs no Windows loader at all: copy the PE headers to RVA 0,
// copy each section to its VirtualAddress, then append a small x86-64 stub that
// calls the entry point and converts the returned eax into Linux exit(60).
//
//     e8 <rel32>       call <AddressOfEntryPoint>
//     89 c7            mov edi, eax
//     b8 3c 00 00 00  mov eax, 60
//     0f 05            syscall
//
// The stub is deliberately a `call`: the PE entry ends in `ret`, and FEXCore's
// shadow call/return stack (already exercised by the M0 self-check) supplies
// the return address. A 42 coming back through HuskSyscall proves that real PE
// bytes were mapped, decoded and executed by the JIT.
// ---------------------------------------------------------------------------
static uint16_t pe_rd16(const uint8_t *p) {
    uint16_t v; memcpy(&v, p, sizeof(v)); return v;
}
static uint32_t pe_rd32(const uint8_t *p) {
    uint32_t v; memcpy(&v, p, sizeof(v)); return v;
}

struct HuskPEHeader {
    uint32_t entry_rva;
    uint32_t size_of_image;
    uint32_t size_of_headers;
    uint16_t section_count;
    const uint8_t *sections;
};

static bool husk_parse_pe32plus(const uint8_t *d, size_t n, HuskPEHeader *out) {
    if (n < 0x40 || d[0] != 'M' || d[1] != 'Z') {
        set_err("PE: no MZ signature"); return false;
    }
    const uint32_t pe = pe_rd32(d + 0x3c);
    if (pe > n || n - pe < 24 || pe_rd32(d + pe) != 0x00004550u) {
        set_err("PE: no PE signature at 0x%x", pe); return false;
    }
    const uint16_t machine = pe_rd16(d + pe + 4);
    const uint16_t nsec = pe_rd16(d + pe + 6);
    const uint16_t optsz = pe_rd16(d + pe + 20);
    if (machine != 0x8664) {
        set_err("PE: machine 0x%x is not x86-64", (unsigned)machine); return false;
    }
    // PE32+ data directories start at +112, so a header smaller than that
    // cannot carry SizeOfImage at +56 / SizeOfHeaders at +60.
    if (optsz < 112 || (uint64_t)pe + 24 + optsz + (uint64_t)nsec * 40 > n) {
        set_err("PE: truncated optional/section headers (optsz=%u nsec=%u)",
                (unsigned)optsz, (unsigned)nsec);
        return false;
    }
    const uint8_t *opt = d + pe + 24;
    if (pe_rd16(opt) != 0x20b) {
        set_err("PE: not PE32+ (magic 0x%x)", (unsigned)pe_rd16(opt)); return false;
    }
    // Reject a relocation directory: this path deliberately has no relocation
    // support, and silently ignoring one would produce a confusing crash.
    const uint32_t nrva = pe_rd32(opt + 108);
    if (nrva > 5 && (pe_rd32(opt + 112 + 5 * 8) || pe_rd32(opt + 112 + 5 * 8 + 4))) {
        set_err("PE: base relocations are not supported by this probe"); return false;
    }
    out->entry_rva = pe_rd32(opt + 16);
    out->size_of_image = pe_rd32(opt + 56);
    out->size_of_headers = pe_rd32(opt + 60);
    out->section_count = nsec;
    out->sections = opt + optsz;
    if (!out->size_of_image || out->size_of_image > (64u << 20)) {
        set_err("PE: bad SizeOfImage 0x%x", out->size_of_image); return false;
    }
    if (out->size_of_headers > n || out->size_of_headers > out->size_of_image) {
        set_err("PE: bad SizeOfHeaders 0x%x", out->size_of_headers); return false;
    }
    if (out->entry_rva >= out->size_of_image) {
        set_err("PE: entry RVA 0x%x outside image", out->entry_rva); return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Run exactly ONE guest program on the shared FEXCore context and return the
// value it handed to Linux exit(60).
//
// M5/M6 (freestanding PE) and M7c (real Wine ntdll.dll) all reach the JIT
// through here. The 16 KiB callret-stack alignment below was hard-won -- an
// unaligned mprotect() failed SILENTLY and the guest's first `call` died with
// a SIGBUS that looked like a guest bug -- so a second, slightly different
// copy of this sequence would be a regression waiting to happen.
//
// `code_base`/`code_size` is the guest range QueryGuestExecutableRange must
// report; it must cover BOTH the entry point and every page the guest runs.
// `gs_base` (M8a) becomes the guest's gs segment base -- FEXCore adds
// CPUState::gs_cached to every gs: operand, so this is all a TEB needs.
// Pass 0 to leave gs alone (M5/M6/M7c touch no segment).
// ---------------------------------------------------------------------------
static int64_t husk_fex_exec(uint64_t entry, uint64_t code_base,
                             uint64_t code_size, uint64_t gs_base) {
    g_code_base = code_base;
    g_code_size = code_size;

    constexpr size_t STACK_SIZE = 0x10000;
    void *stack = ::mmap(nullptr, STACK_SIZE, PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (stack == MAP_FAILED) { set_err("PE: stack mmap failed"); return -25; }
    uint64_t *sp = reinterpret_cast<uint64_t *>(
        reinterpret_cast<uint64_t>(stack) + STACK_SIZE);
    *(--sp) = 0; // AT_NULL value
    *(--sp) = 0; // AT_NULL type
    *(--sp) = 0; // envp[0]
    *(--sp) = 0; // argv[0]
    *(--sp) = 0; // argc
    const uint64_t start_sp = reinterpret_cast<uint64_t>(sp);

    husk_pe_trace("before-create", entry, start_sp);
    auto *thread = g_ctx->CreateThread(entry, start_sp);
    husk_pe_trace("after-create", reinterpret_cast<uint64_t>(thread), 0);
    if (!thread) {
        set_err("PE: CreateThread null");
        ::munmap(stack, STACK_SIZE);
        return -26;
    }
    {
        constexpr size_t CR = FEXCore::Core::InternalThreadState::CALLRET_STACK_SIZE;
        // iOS arm64 uses 16 KiB pages (sysctl hw.pagesize = 16384). mprotect()
        // requires a page-aligned start, so the guard offset MUST be 0x4000 --
        // the M0 probe already does this. Using PAGE=0x1000 here left crbase
        // unaligned: mprotect silently failed, the shadow call/ret stack stayed
        // PROT_NONE, and the PE stub's `call` faulted while pushing its return
        // address (SIGBUS, swallowed by the trap guard, hence no .ips report).
        constexpr size_t PG = 0x4000;
        void *a = ::mmap(nullptr, CR + 2 * PG, PROT_NONE,
                         MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (a == MAP_FAILED) {
            set_err("PE: callret mmap failed");
            ::munmap(stack, STACK_SIZE);
            return -27;
        }
        void *crbase = static_cast<uint8_t *>(a) + PG;
        if (::mprotect(crbase, CR, PROT_READ | PROT_WRITE) != 0) {
            set_err("PE: callret mprotect failed (crbase=%p CR=0x%zx PG=0x%zx)",
                    crbase, CR, PG);
            ::munmap(a, CR + 2 * PG);
            ::munmap(stack, STACK_SIZE);
            return -28;
        }
        // Prove the region is writable before the JIT ever touches it.
        *reinterpret_cast<volatile uint8_t *>(crbase) = 0;
        husk_pe_trace("callret-writable", reinterpret_cast<uint64_t>(crbase), CR);
        thread->CallRetStackBase = crbase;
        thread->CurrentFrame->State.callret_sp =
            reinterpret_cast<uint64_t>(crbase) + CR / 4;
    }
    {
        static FEXCore::Core::CPUState::gdt_segment gdt[1] = {};
        gdt[0].L = 1; gdt[0].D = 0; gdt[0].P = 1; gdt[0].S = 1;
        gdt[0].Type = 0b1011;
        thread->CurrentFrame->State.segment_arrays[0] = gdt;
        thread->CurrentFrame->State.cs_idx = 0;
    }
    if (gs_base) {
        // M8a: the guest's gs base. Must be set AFTER CreateThread, because
        // CurrentFrame is what the JIT reads gs_cached from on every gs: op.
        thread->CurrentFrame->State.gs_cached = gs_base;
        husk_pe_trace("gs-base", gs_base, 0);
    }

    g_exit_code = -99;
    husk_pe_trace("before-exec", entry, 0);
    if (setjmp(g_exit_jmp) == 0) {
        g_ctx->ExecuteThread(thread);
        set_err("PE: ExecuteThread returned without exit");
        g_exit_code = -9;
    }
    const int64_t rc = g_exit_code;
    husk_pe_trace("guest-exit", static_cast<uint64_t>(rc), 0);
    ::munmap(stack, STACK_SIZE);
    return rc;
}

static int64_t husk_fex_run_pe(const uint8_t *file, size_t file_size,
                               bool win_mode, bool use_ws) {
    // M6: arm the Windows syscall dispatcher only for the probe that owns this
    // launch's single guest thread. M0/M5 pass false and keep the Linux path.
    // M6b additionally arms the wineserver forwarding for one syscall.
    g_win_mode = win_mode;
    g_win_use_ws = use_ws;
    g_ws_call_ok = false;
    g_win_seq = 0;
    g_win_hits = 0;
    // A launch runs exactly ONE guest program. The PE marker does not run the
    // M0 self-check, so initialise the Context here WITHOUT creating that
    // first guest thread. Calling husk_fex_probe() here would create two
    // threads and crash on iOS 12.2 (SIGBUS in the second JIT code buffer).
    if (!g_ctx) {
        std::lock_guard<std::mutex> lock(g_lock);
        if (!g_ctx) {
            const int64_t initrc = husk_fex_init();
            if (initrc != 0 || !g_ctx) {
                set_err("PE: FEXCore init failed (rc=%lld)", (long long)initrc);
                return -20;
            }
        }
    }
    husk_pe_trace("context-ready", 0, 0);

    HuskPEHeader pe{};
    if (!husk_parse_pe32plus(file, file_size, &pe)) return -21;

    constexpr size_t PAGE = 0x1000;
    const size_t stub_rva = (pe.size_of_image + PAGE - 1) & ~(PAGE - 1);
    const size_t map_size = stub_rva + PAGE;
    void *image = ::mmap(nullptr, map_size, PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (image == MAP_FAILED) { set_err("PE: image mmap failed"); return -22; }
    uint8_t *base = static_cast<uint8_t *>(image);

    memcpy(base, file, pe.size_of_headers);
    for (uint16_t i = 0; i < pe.section_count; i++) {
        const uint8_t *s = pe.sections + (size_t)i * 40;
        const uint32_t va = pe_rd32(s + 12);
        const uint32_t rawsize = pe_rd32(s + 16);
        const uint32_t raw = pe_rd32(s + 20);
        if (!rawsize) continue;
        if ((uint64_t)va + rawsize > map_size ||
            (uint64_t)raw + rawsize > file_size) {
            set_err("PE: section %u out of range (va=0x%x raw=0x%x size=0x%x)",
                    (unsigned)i, va, raw, rawsize);
            ::munmap(image, map_size);
            return -23;
        }
        memcpy(base + va, file + raw, rawsize);
    }

    // M5 stub (Linux): call the real PE entry, then convert its eax into
    // Linux exit(60).
    static const uint8_t kLinuxStub[] = {
        0xE8, 0x00, 0x00, 0x00, 0x00,             // call rel32 -> PE entry
        0x89, 0xC7,                               // mov edi, eax
        0xB8, 0x3C, 0x00, 0x00, 0x00,             // mov eax, 60
        0x0F, 0x05,                               // syscall
    };
    // M6 stub (Windows): call the SAME real PE entry (eax = 42), stash the
    // answer in ebx, then make four consecutive Windows x64 syscalls in
    // Wine's own stub form (mov r10,rcx; mov eax,<id>; syscall). This proves
    // more than "one syscall works": the JIT must resume guest execution after
    // every syscall, and the handler's NTSTATUS must land back in RAX.
    //
    //   1 NtClose(0x1111)                       id 15 -> STATUS_SUCCESS
    //   2 NtQueryInformationProcess(0x2222,0x3333) id 25 -> STATUS_SUCCESS
    //   3 NtCreateFile(0x4444,0x5555)          id 85 -> STATUS_NOT_IMPLEMENTED
    //       cmp eax,0xC0000002 / je +5 / mov ebx,-1   (poison the exit code if
    //       the NTSTATUS was not written back, or the guest did not resume)
    //   4 NtTerminateProcess(0x6666, ebx)      id 44 -> guest exits with 42
    //
    // The 0x1111..0x6666 markers are checked host-side in husk_win_dispatch,
    // so a wrong Windows ABI argument mapping cannot produce a green result.
    static const uint8_t kWinStub[] = {
        0xE8, 0x00, 0x00, 0x00, 0x00,             // call rel32 -> PE entry
        0x89, 0xC3,                               // mov ebx, eax  (stash 42)
        // NtClose
        0xB9, 0x11, 0x11, 0x00, 0x00,             // mov ecx, 0x1111
        0x4C, 0x8B, 0xD1,                         // mov r10, rcx
        0xB8, 0x0F, 0x00, 0x00, 0x00,             // mov eax, 15
        0x0F, 0x05,                               // syscall
        // NtQueryInformationProcess
        0xB9, 0x22, 0x22, 0x00, 0x00,             // mov ecx, 0x2222
        0xBA, 0x33, 0x33, 0x00, 0x00,             // mov edx, 0x3333
        0x4C, 0x8B, 0xD1,                         // mov r10, rcx
        0xB8, 0x19, 0x00, 0x00, 0x00,             // mov eax, 25
        0x0F, 0x05,                               // syscall
        // NtCreateFile (deliberately unimplemented)
        0xB9, 0x44, 0x44, 0x00, 0x00,             // mov ecx, 0x4444
        0xBA, 0x55, 0x55, 0x00, 0x00,             // mov edx, 0x5555
        0x4C, 0x8B, 0xD1,                         // mov r10, rcx
        0xB8, 0x55, 0x00, 0x00, 0x00,             // mov eax, 85
        0x0F, 0x05,                               // syscall
        0x3D, 0x02, 0x00, 0x00, 0xC0,             // cmp eax, 0xC0000002
        0x74, 0x05,                               // je +5
        0xBB, 0xFF, 0xFF, 0xFF, 0xFF,             // mov ebx, -1
        // NtTerminateProcess
        0xB9, 0x66, 0x66, 0x00, 0x00,             // mov ecx, 0x6666
        0x89, 0xDA,                               // mov edx, ebx
        0x4C, 0x8B, 0xD1,                         // mov r10, rcx
        0xB8, 0x2C, 0x00, 0x00, 0x00,             // mov eax, 44
        0x0F, 0x05,                               // syscall
    };
    static_assert(sizeof(kWinStub) < 256, "M6 stub must fit one PE page");
    const uint8_t *tmpl = win_mode ? kWinStub : kLinuxStub;
    const size_t stub_len = win_mode ? sizeof(kWinStub) : sizeof(kLinuxStub);
    uint8_t stub[256];
    memcpy(stub, tmpl, stub_len);
    const int64_t rel = (int64_t)pe.entry_rva - (int64_t)(stub_rva + 5);
    if (rel < -2147483648LL || rel > 2147483647LL) {
        set_err("PE: entry too far from stub"); ::munmap(image, map_size); return -24;
    }
    const int32_t rel32 = static_cast<int32_t>(rel);
    memcpy(stub + 1, &rel32, sizeof(rel32));
    memcpy(base + stub_rva, stub, stub_len);

    const uint64_t image_addr = reinterpret_cast<uint64_t>(image);
    husk_pe_trace(win_mode ? "m6-mapped" : "mapped",
                  image_addr, (uint64_t)stub_len);
    husk_pe_trace("mapped", image_addr, map_size);

    const int64_t rc = husk_fex_exec(image_addr + stub_rva, image_addr, map_size, 0);
    fprintf(stderr,
            "[husk-pe] image=%p map=0x%zx sections=%u entry=0x%x stub=0x%zx exit=%lld\n",
            image, map_size, (unsigned)pe.section_count, pe.entry_rva,
            stub_rva, (long long)rc);

    int64_t result = rc;
    if (win_mode) {
        // A green M6 needs ALL FOUR Windows syscalls, in order, each with the
        // correct R10/RDX arguments (bit n is set only when call n matched).
        // rc==42 alone is not enough: a broken NTSTATUS write-back or a JIT
        // that stops after the first syscall would poison ebx and exit -1.
        husk_pe_trace("m6-dispatch", g_win_hits, g_win_seq);
        if (g_win_hits != 0xFu || g_win_seq != 4u) {
            set_err("M6: dispatch mismatch hits=0x%x seq=%u (want 0xf/4)",
                    (unsigned)g_win_hits, (unsigned)g_win_seq);
            result = -31;
        }
        if (use_ws && !g_ws_call_ok) {
            // M6b's whole point is the guest -> wineserver -> guest round
            // trip. rc=42 alone must not be reported as success if the server
            // request never completed.
            set_err("M6b: wineserver request did not complete");
            result = -32;
        }
    }

    g_win_mode = false;
    g_win_use_ws = false;
    // No further guest thread will run; stop reporting an unmapped range.
    g_code_base = 0;
    g_code_size = 0;
    ::munmap(image, map_size);
    return result;
}

static int64_t husk_bundle_pe_probe(bool win_mode, bool use_ws) {
    g_err[0] = 0;
    // hello.exe sits next to the executable in Husk.app (project.yml copies
    // Resources/** to the bundle root, exactly like l_intl.nls). Both M5 and
    // M6 execute the SAME real PE bytes; only the appended stub differs.
    char path[4096];
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) != 0) {
        set_err("PE: executable path too long"); return -1;
    }
    const char *slash = strrchr(path, '/');
    if (!slash) { set_err("PE: bad executable path %s", path); return -1; }
    const size_t prefix = static_cast<size_t>(slash - path) + 1;
    static const char res[] = "hello.exe";
    if (prefix + sizeof(res) > sizeof(path)) {
        set_err("PE: bundle path too long"); return -1;
    }
    memcpy(path + prefix, res, sizeof(res)); // includes the trailing NUL

    FILE *f = fopen(path, "rb");
    if (!f) { set_err("PE: cannot open %s", path); return -2; }
    if (fseek(f, 0, SEEK_END) != 0) {
        fclose(f); set_err("PE: fseek failed on %s", path); return -3;
    }
    const long n = ftell(f);
    if (n <= 0 || n > (16 << 20)) {
        fclose(f); set_err("PE: bad image size %ld in %s", n, path); return -3;
    }
    rewind(f);
    uint8_t *buf = new uint8_t[(size_t)n];
    const size_t got = fread(buf, 1, (size_t)n, f);
    fclose(f);
    if (got != (size_t)n) {
        delete[] buf;
        set_err("PE: short read (%zu of %ld)", got, n);
        return -4;
    }
    fprintf(stderr, "[husk-%s] bundle image %s (%zu bytes)\n",
            use_ws ? "m6b" : (win_mode ? "m6" : "pe"), path, got);
    const int64_t rc = husk_fex_run_pe(buf, got, win_mode, use_ws);
    delete[] buf;
    return rc;
}

int64_t husk_pe_probe(void) {
    return husk_bundle_pe_probe(false, false);
}

const char *husk_pe_last_error(void) {
    return g_err[0] ? g_err : nullptr;
}

// ---------------------------------------------------------------------------
// M6: Windows syscall id -> handler dispatch
//
// Wine's PE ntdll.dll has 258 distinct syscall ids (0..257, 516 Nt*/Zw*
// stubs). Each stub is
//     4c 8b d1            mov r10, rcx     ; syscall overwrites rcx with RIP
//     b8 <id32>           mov eax, <id>
//     f6 04 25 08 03 fe 7f 01  test byte [0x7ffe0308], 1
//     75 03               jne <wineserver path>
//     0f 05               syscall
//     c3                  ret
// so RAX is the id and the arguments are in R10/RDX/R8/R9. FEXCore's
// OS_LINUX64 SyscallArguments is RAX,RDI,RSI,RDX,R10,R8,R9: it exposes the
// very same registers AND writes the handler's return value back to RAX.
// husk_win_syscall_name() comes from the generated 258-entry table in
// HuskWinSyscalls.h (exported from m5_artifact/ntdll.dll).
//
// M6a implements the four ids the probe exercises. Everything else returns
// STATUS_NOT_IMPLEMENTED instead of killing the guest; M6b will route real
// ids (NtCreateFile, NtOpenFile, ...) to wineserver requests.
// ---------------------------------------------------------------------------
static void husk_win_trace(uint32_t id, const char *name, uint64_t a1, uint64_t a2) {
    char buf[256];
    int n = snprintf(buf, sizeof(buf),
                     "[husk-m6] id=%u %s r10=0x%llx rdx=0x%llx seq=%u\n",
                     (unsigned)id, name ? name : "<unknown>",
                     (unsigned long long)a1, (unsigned long long)a2,
                     (unsigned)g_win_seq);
    if (n > 0) (void)::write(2, buf, static_cast<size_t>(n));
}

static uint64_t husk_win_dispatch(FEXCore::HLE::SyscallArguments *args) {
    const uint32_t id = static_cast<uint32_t>(args->Argument[0]); // RAX
    // Windows x64 syscall arguments AFTER Wine's `mov r10,rcx`:
    const uint64_t a1 = args->Argument[4]; // R10 (was RCX)
    const uint64_t a2 = args->Argument[3]; // RDX
    const uint64_t a3 = args->Argument[5]; // R8
    const uint64_t a4 = args->Argument[6]; // R9
    (void)a3; (void)a4;
    const char *name = husk_win_syscall_name(id);
    const uint32_t seq = g_win_seq++;
    husk_win_trace(id, name, a1, a2);

    // Bit n is set only when the n-th syscall has the right id AND the right
    // argument registers. 0xf is required after the guest exits.
#define HUSK_WIN_HIT(n) do { if (seq == (n)) g_win_hits |= (1u << (n)); } while (0)

    switch (id) {
    case 15: // NtClose
        if (a1 == 0x1111u) HUSK_WIN_HIT(0);
        return 0x00000000u; // STATUS_SUCCESS
    case 25: // NtQueryInformationProcess
        if (a1 == 0x2222u && a2 == 0x3333u) HUSK_WIN_HIT(1);
        if (g_win_use_ws) {
            // M6b: this is the first guest Windows syscall that reaches the
            // in-process wineserver. REQ_get_process_info is 9 in the local
            // server_protocol.h (gen_m6b_layout.py asserts the enum); its
            // only field is `obj_handle_t handle` at offset 12, and
            // handle.c's get_magic_handle() maps 0xffffffff to
            // current->process, so no real handle table entry is needed.
            // The 64-byte reply carries the NTSTATUS in reply_header.error,
            // exactly the value the guest expects back in RAX.
            const uint32_t pseudo_handle = 0xffffffffu;
            unsigned int status = 0;
            const int32_t rc = husk_ws_call(9, &pseudo_handle,
                                            sizeof(pseudo_handle), &status);
            if (rc == 0) {
                g_ws_call_ok = true;
                return status;
            }
            return 0xC0000001ULL; // STATUS_UNSUCCESSFUL
        }
        return 0x00000000u; // STATUS_SUCCESS (probe passes no output buffer)
    case 85: // NtCreateFile: deliberately not routed to wineserver yet.
        if (a1 == 0x4444u && a2 == 0x5555u) HUSK_WIN_HIT(2);
        return 0xC0000002ULL; // STATUS_NOT_IMPLEMENTED
    case 44: // NtTerminateProcess(handle, exit_status)
        if (a1 == 0x6666u) HUSK_WIN_HIT(3);
        g_exit_code = static_cast<int32_t>(static_cast<uint32_t>(a2));
        longjmp(g_exit_jmp, 1);
        return 0; // unreachable, keeps the compiler's return-path check happy
    default:
        return 0xC0000002ULL; // STATUS_NOT_IMPLEMENTED
    }
#undef HUSK_WIN_HIT
}

int64_t husk_m6_probe(void) {
    return husk_bundle_pe_probe(true, false);
}

int64_t husk_m6b_probe(void) {
    // The Swift launcher calls husk_ws_start() first, so the retained
    // wineserver channel is live before the guest thread is created.
    if (!husk_ws_is_ready()) {
        set_err("M6b: wineserver channel is not ready");
        return -33;
    }
    return husk_bundle_pe_probe(true, true);
}

const char *husk_m6_last_error(void) {
    return g_err[0] ? g_err : nullptr;
}

// ---------------------------------------------------------------------------
// M7a: load the REAL Wine ntdll.dll -- sections, relocations, exports.
//
// Deliberately HOST-SIDE ONLY: no FEXCore guest thread, no TEB/PEB, no
// LdrInitializeThunk. M5/M6 proved that a freestanding 5.7 KB PE can be
// mapped and executed; they said nothing about a 4.8 MB Windows DLL with 19
// sections, 192 base relocations and 1466 exports. This probe lays that image
// out in this process and checks that every structure resolves consistently.
//
// It also MEASURES the structural problem M7b must solve: sections are 4 KB
// aligned while the device page size is 16 KB, so mprotect() cannot give each
// section its exact RX/RW/R permission. We report the number of 16 KB pages
// that need both X and W, without treating it as a probe failure.
//
// The expected constants come from m7_loader_spec.json; check_m7.py asserts
// they still match the real DLL, so a stale image cannot silently pass.
// ---------------------------------------------------------------------------
#define HUSK_M7_PAGE           0x4000u
#define HUSK_M7_MAX_PAGES      1200u
#define HUSK_M7_IMAGE_BASE     0x170000000ULL
#define HUSK_M7_SIZE_IMAGE     0x43e000u
#define HUSK_M7_SECTIONS       19u
#define HUSK_M7_DIR64          189u
#define HUSK_M7_RELOC_PAD      3u
#define HUSK_M7_RELOC_BLOCKS   12u
#define HUSK_M7_EXPORTS        1466u
#define HUSK_M7_LDR_INIT_RVA   0x15b00u
#define HUSK_M7_DISPATCH_RVA   0xa7068u

struct HuskM7PE {
    uint64_t image_base;
    uint32_t size_of_image;
    uint32_t size_of_headers;
    uint16_t section_count;
    const uint8_t *sections;
    uint32_t reloc_rva, reloc_size;
    uint32_t export_rva, export_size;
    uint32_t exception_size;
};

struct HuskM7Mapping {
    void *p;
    size_t n;
    ~HuskM7Mapping() {
        if (p && p != MAP_FAILED) ::munmap(p, n);
    }
};

// ---------------------------------------------------------------------------
// M7b: give the mapped image the protection its sections ask for.
//
// iOS refuses an RWX mapping without a JIT entitlement, so a loader cannot
// leave 4.8 MB of guest memory PROT_READ|PROT_WRITE and call it done. The page
// plan is not guessed here: gen_m7b_page_map.py derives it from the same
// section table, and check_m7b.py asserts the run/page counts below against
// that file, so a stale image cannot silently pass.
//
// SectionAlignment is 4 KB while a device page is 16 KB, so pages are merged
// by required permission; M7a measured that no 16 KB page needs both W and X
// (mixed16k=0), which is what makes real W^X-safe protection possible at all.
// ---------------------------------------------------------------------------
#define HUSK_M7B_RUNS    5u    /* contiguous ranges with equal protection */
#define HUSK_M7B_RX      31u
#define HUSK_M7B_RW       6u
#define HUSK_M7B_R       235u
#define HUSK_M7C_RUNS    6u    /* M7c/M8a add one RX range for the thunk page */
#define HUSK_M7C_RX      32u
#define HUSK_M7C_R       234u
/* Both thunks live in the 8 KiB of page 271 that SizeOfImage leaves unused. */
#define HUSK_M7C_STUB_RVA    0x43e000u

struct HuskM7Prot {
    uint32_t calls;         // mprotect() ranges issued
    uint32_t ok;            // ranges that ended up protected
    uint32_t fail;
    uint32_t verified;      // ranges whose protection read back as requested
    uint32_t exec_refused;  // ranges where PROT_EXEC had to be dropped
    uint32_t rx, rw, r, none, wx;
};

// perms[] bit 0 = needs X, bit 1 = needs W. Every byte of this image is
// readable, so PROT_READ is the floor -- PROT_NONE is never correct here.
static int husk_m7_prot(uint8_t mask) {
    int p = PROT_READ;
    if (mask & 2u) p |= PROT_WRITE;
    if (mask & 1u) p |= PROT_EXEC;
    return p;
}

// Ask the kernel what protection a page really has; mprotect() returning 0 is
// not proof (the 16 KiB alignment lesson from M5). iOS only exports the
// vm_region flavour of this query, and even that may be unavailable on some
// builds -- callers treat "could not ask" differently from "wrong answer".
static bool husk_m7_query_prot(void *addr, int *prot) {
    vm_address_t a = reinterpret_cast<vm_address_t>(addr);
    vm_size_t sz = 0;
    natural_t depth = 0;
    vm_region_submap_info_data_64_t info;
    mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
    const kern_return_t kr = ::vm_region_recurse_64(
        mach_task_self(), &a, &sz, &depth,
        reinterpret_cast<vm_region_recurse_info_t>(&info), &cnt);
    if (kr != KERN_SUCCESS) return false;
    *prot = info.protection;
    return true;
}

static bool husk_m7_protect(uint8_t *base, size_t map_size, const uint8_t *perms,
                            uint32_t npages, HuskM7Prot *st) {
    memset(st, 0, sizeof(*st));
    uint32_t pg = 0;
    while (pg < npages) {
        int prot = husk_m7_prot(perms[pg]);
        uint32_t end = pg + 1;
        while (end < npages && husk_m7_prot(perms[end]) == prot) end++;
        const size_t bytes = static_cast<size_t>(end - pg) * HUSK_M7_PAGE;
        uint8_t *addr = base + static_cast<size_t>(pg) * HUSK_M7_PAGE;
        if (addr + bytes > base + map_size) {
            set_err("M7b: run ends past the mapping (page %u)", pg);
            return false;
        }
        st->calls++;
        int mrc = ::mprotect(addr, bytes, prot);
        if (mrc != 0 && (prot & PROT_EXEC)) {
            // Some iOS configurations refuse PROT_EXEC on anonymous memory
            // without a JIT entitlement. That is a device CAPABILITY, not a
            // loader bug: drop X, keep R/W, and report it honestly.
            st->exec_refused++;
            prot &= ~PROT_EXEC;
            mrc = ::mprotect(addr, bytes, prot);
        }
        if (mrc == 0) st->ok++;
        else st->fail++;

        int got = 0;
        const int want = prot & (PROT_READ | PROT_WRITE | PROT_EXEC);
        if (husk_m7_query_prot(addr, &got) &&
            (got & (PROT_READ | PROT_WRITE | PROT_EXEC)) == want) {
            st->verified++;
        }
        for (uint32_t k = pg; k < end; k++) {
            if ((prot & PROT_WRITE) && (prot & PROT_EXEC)) st->wx++;
            else if (prot & PROT_EXEC) st->rx++;
            else if (prot & PROT_WRITE) st->rw++;
            else st->r++;
        }
        pg = end;
    }
    return st->fail == 0 && st->verified == st->calls && st->wx == 0;
}

// ---------------------------------------------------------------------------
// M8a: the first guest code that needs a TEB and a PEB.
//
// `RtlGetCurrentPeb` (RVA 0x29140) is exactly three instructions:
//     mov rax, qword ptr gs:[0x30]    ; NT_TIB.Self == the TEB address
//     mov rax, qword ptr [rax+0x60]   ; TEB.ProcessEnvironmentBlock
//     ret
// so ONE call checks three independent things at once: FEXCore's gs segment
// base (CPUState::gs_cached), the +0x30/+0x60 TEB layout, and that ntdll hands
// back OUR PEB. No LdrInitializeThunk, no LdrpInitialize, no heap.
//
// The thunk then reads PEB->ImageBaseAddress (PEB+0x10) and compares both
// pointers against slots filled with the real runtime addresses, so a stale or
// cross-wired value cannot pass.
// ---------------------------------------------------------------------------
#define HUSK_M8A_RTLGETPEB  0x29140u
#define HUSK_M8A_TEB_SELF   0x30u   /* NT_TIB.Self inside the x64 TEB */
#define HUSK_M8A_TEB_PEB    0x60u   /* TEB.ProcessEnvironmentBlock */
#define HUSK_M8A_PEB_IMAGE  0x10u   /* PEB.ImageBaseAddress */
#define HUSK_M8A_SLOT_PEB   0x60u   /* thunk page: expected PEB pointer */
#define HUSK_M8A_SLOT_IMG   0x68u   /* thunk page: expected image base */

static bool husk_m8a_make_teb(uint64_t *teb_out, uint64_t *peb_out,
                             uint64_t image_base) {
    constexpr size_t SZ = 0x4000;   // 16 KiB: one device page, never split
    void *teb = ::mmap(nullptr, SZ, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (teb == MAP_FAILED) { set_err("M8a: TEB mmap failed"); return false; }
    void *peb = ::mmap(nullptr, SZ, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (peb == MAP_FAILED) {
        set_err("M8a: PEB mmap failed");
        ::munmap(teb, SZ);
        return false;
    }
    uint8_t *t = static_cast<uint8_t *>(teb);
    uint8_t *p = static_cast<uint8_t *>(peb);
    memset(t, 0, 0x100);
    memset(p, 0, 0x100);

    const uint64_t taddr = reinterpret_cast<uint64_t>(teb);
    const uint64_t paddr = reinterpret_cast<uint64_t>(peb);
    memcpy(t + HUSK_M8A_TEB_SELF, &taddr, 8);
    memcpy(t + HUSK_M8A_TEB_PEB, &paddr, 8);
    memcpy(p + HUSK_M8A_PEB_IMAGE, &image_base, 8);
    // A canary the guest does NOT read: if ntdll or the JIT scribbled over the
    // structures, the host-side read-back after the run will notice.
    const uint64_t canary = 0x4855534b4d384100ULL;  // "HUSKM8A\0"
    memcpy(t + 0xf0, &canary, 8);
    memcpy(p + 0xf0, &canary, 8);

    *teb_out = taddr;
    *peb_out = paddr;
    return true;
}

static bool husk_m8a_write_stub(uint8_t *base, size_t map_size,
                                uint64_t peb, uint64_t image_base) {
    static const uint8_t tmpl[] = {
        0xE8, 0, 0, 0, 0,                         // call RtlGetCurrentPeb
        0x4C, 0x8B, 0x15, 0, 0, 0, 0,             // mov r10, [rip+slot_peb]
        0x4C, 0x39, 0xD0,                         // cmp rax, r10
        0x75, 0,                                  // jne fail1 (patched)
        0x48, 0x8B, 0x40, 0x10,                   // mov rax, [rax+0x10]
        0x4C, 0x8B, 0x15, 0, 0, 0, 0,             // mov r10, [rip+slot_image]
        0x4C, 0x39, 0xD0,                         // cmp rax, r10
        0x75, 0,                                  // jne fail2 (patched)
        0xBF, 0x2A, 0x00, 0x00, 0x00,             // mov edi, 42
        0xB8, 0x3C, 0x00, 0x00, 0x00,             // mov eax, 60
        0x0F, 0x05,                               // syscall
        0x0F, 0x0B,                               // ud2 (unreachable)
        // fail1 @0x2f: the PEB pointer itself came back wrong
        0xBF, 0xC8, 0x00, 0x00, 0x00,             // mov edi, 200
        0xB8, 0x3C, 0x00, 0x00, 0x00,             // mov eax, 60
        0x0F, 0x05,                               // syscall
        // fail2 @0x3b: PEB->ImageBaseAddress came back wrong
        0xBF, 0xD2, 0x00, 0x00, 0x00,             // mov edi, 210
        0xB8, 0x3C, 0x00, 0x00, 0x00,             // mov eax, 60
        0x0F, 0x05,                               // syscall
    };
    if ((uint64_t)HUSK_M7C_STUB_RVA + sizeof(tmpl) > map_size) {
        set_err("M8a: thunk does not fit the tail page"); return false;
    }
    uint8_t *stub = base + HUSK_M7C_STUB_RVA;
    memcpy(stub, tmpl, sizeof(tmpl));

    const int64_t rtl_off =
        (int64_t)HUSK_M8A_RTLGETPEB - (int64_t)HUSK_M7C_STUB_RVA;
    struct Patch { uint32_t at; int64_t target; uint32_t next; };
    const Patch patches[] = {
        {0x01, rtl_off, 0x05},
        {0x08, (int64_t)HUSK_M8A_SLOT_PEB, 0x0C},
        {0x18, (int64_t)HUSK_M8A_SLOT_IMG, 0x1C},
    };
    for (const Patch &q : patches) {
        const int64_t disp = q.target - (int64_t)q.next;
        if (disp < -2147483648LL || disp > 2147483647LL) {
            set_err("M8a: displacement out of range (0x%llx)",
                    (unsigned long long)disp);
            return false;
        }
        const int32_t d32 = static_cast<int32_t>(disp);
        memcpy(stub + q.at, &d32, sizeof(d32));
    }
    stub[0x10] = static_cast<uint8_t>(0x2F - 0x11);   // jne fail1
    stub[0x20] = static_cast<uint8_t>(0x3B - 0x21);   // jne fail2

    memcpy(stub + HUSK_M8A_SLOT_PEB, &peb, 8);
    memcpy(stub + HUSK_M8A_SLOT_IMG, &image_base, 8);
    return true;
}

// ---------------------------------------------------------------------------
// M7c: execute code that came out of the Windows binary.
//
// SizeOfImage ends at 0x43e000, i.e. 8 KB before the end of page 271, so the
// unused tail of that page is a safe home for the thunk -- no extra mapping,
// and the image itself is untouched.
//
// The thunk calls RtlCompareMemory (RVA 0x1de80) twice through the Windows x64
// ABI (rcx, rdx, r8) and exits with 42 only if BOTH answers are right:
//
//   call 1: 16 bytes differing at index 9   -> expects 9
//   call 2: 16 identical bytes              -> expects 16 (length, not index)
//
// The data lives at fixed offsets inside the same page and is addressed
// RIP-relative, so the probe depends on no register the guest may clobber and
// on no host-provided pointer. Exit codes 100+n / 150+n report the wrong
// answer from call 1 / call 2 instead of a bare failure.
// ---------------------------------------------------------------------------
#define HUSK_M7C_RTLCOMPARE  0x1de80u
#define HUSK_M7C_DATA1       0x80u
#define HUSK_M7C_DATA2       0x90u
#define HUSK_M7C_DATA3       0xa0u
#define HUSK_M7C_DATA4       0xb0u

static bool husk_m7c_write_stub(uint8_t *base, size_t map_size) {
    // Placeholders (0x00) are patched below; check_m7b.py decodes the result
    // with capstone and asserts every displacement and branch target.
    static const uint8_t tmpl[] = {
        0x48, 0x8D, 0x0D, 0, 0, 0, 0,             // lea rcx, [rip+d1]
        0x48, 0x8D, 0x15, 0, 0, 0, 0,             // lea rdx, [rip+d2]
        0x41, 0xB8, 0x10, 0x00, 0x00, 0x00,       // mov r8d, 16
        0xE8, 0, 0, 0, 0,                         // call RtlCompareMemory
        0x83, 0xF8, 0x09,                         // cmp eax, 9
        0x75, 0,                                  // jne fail1 (patched)
        0x48, 0x8D, 0x0D, 0, 0, 0, 0,             // lea rcx, [rip+d3]
        0x48, 0x8D, 0x15, 0, 0, 0, 0,             // lea rdx, [rip+d4]
        0x41, 0xB8, 0x10, 0x00, 0x00, 0x00,       // mov r8d, 16
        0xE8, 0, 0, 0, 0,                         // call RtlCompareMemory
        0x83, 0xF8, 0x10,                         // cmp eax, 16
        0x75, 0,                                  // jne fail2 (patched)
        0xBF, 0x2A, 0x00, 0x00, 0x00,             // mov edi, 42
        0xB8, 0x3C, 0x00, 0x00, 0x00,             // mov eax, 60
        0x0F, 0x05,                               // syscall
        0x0F, 0x0B,                               // ud2 (unreachable)
        // fail1 @0x4a: exit 100 + eax
        0x83, 0xC0, 0x64,                         // add eax, 100
        0x89, 0xC7,                               // mov edi, eax
        0xB8, 0x3C, 0x00, 0x00, 0x00,             // mov eax, 60
        0x0F, 0x05,                               // syscall
        // fail2 @0x56: exit 150 + eax
        0x83, 0xC0, 0x96,                         // add eax, 150
        0x89, 0xC7,                               // mov edi, eax
        0xB8, 0x3C, 0x00, 0x00, 0x00,             // mov eax, 60
        0x0F, 0x05,                               // syscall
    };
    if ((uint64_t)HUSK_M7C_STUB_RVA + sizeof(tmpl) > map_size) {
        set_err("M7c: thunk does not fit the tail page"); return false;
    }
    uint8_t *stub = base + HUSK_M7C_STUB_RVA;
    memcpy(stub, tmpl, sizeof(tmpl));

    // Displacements are computed PAGE-RELATIVE: the data blocks and the call
    // target are both addressed from this one page, so `target_off - next_off`
    // is exact and independent of where iOS actually maps the image.
    const int64_t rtl_off =
        (int64_t)HUSK_M7C_RTLCOMPARE - (int64_t)HUSK_M7C_STUB_RVA;
    struct Patch { uint32_t at; int64_t target; uint32_t next; };
    const Patch patches[] = {
        {0x03, (int64_t)HUSK_M7C_DATA1, 0x07},
        {0x0A, (int64_t)HUSK_M7C_DATA2, 0x0E},
        {0x15, rtl_off, 0x19},
        {0x21, (int64_t)HUSK_M7C_DATA3, 0x25},
        {0x28, (int64_t)HUSK_M7C_DATA4, 0x2C},
        {0x33, rtl_off, 0x37},
    };
    for (const Patch &q : patches) {
        const int64_t disp = q.target - (int64_t)q.next;
        if (disp < -2147483648LL || disp > 2147483647LL) {
            set_err("M7c: displacement out of range (0x%llx)",
                    (unsigned long long)disp);
            return false;
        }
        const int32_t d32 = static_cast<int32_t>(disp);
        memcpy(stub + q.at, &d32, sizeof(d32));
    }
    stub[0x1D] = static_cast<uint8_t>(0x4A - 0x1E);   // jne fail1
    stub[0x3B] = static_cast<uint8_t>(0x56 - 0x3C);   // jne fail2

    for (uint32_t i = 0; i < 16; i++) {
        stub[HUSK_M7C_DATA1 + i] = static_cast<uint8_t>(i);
        stub[HUSK_M7C_DATA3 + i] = static_cast<uint8_t>(0x20 + i);
        // Call 1 differs at index 9; call 2 is byte-identical to its partner.
        stub[HUSK_M7C_DATA2 + i] =
            static_cast<uint8_t>(i == 9 ? 0xFF : i);
        stub[HUSK_M7C_DATA4 + i] = static_cast<uint8_t>(0x20 + i);
    }
    return true;
}

// Owned by the fixture too: compare a NUL-terminated name inside the mapped
// image against a literal without pulling in strcmp/memcmp declarations.
static bool husk_m7_name_eq(const uint8_t *base, uint32_t limit,
                            uint32_t rva, const char *want) {
    if (rva >= limit) return false;
    const uint8_t *s = base + rva;
    for (uint32_t i = 0; i < 256; i++) {
        if (rva + i >= limit) return false;
        const char c = static_cast<char>(s[i]);
        if (c != want[i]) return false;
        if (c == 0) return true;
    }
    return false;
}

static bool husk_m7_parse(const uint8_t *d, size_t n, HuskM7PE *out) {
    if (n < 0x40 || d[0] != 'M' || d[1] != 'Z') {
        set_err("M7: no MZ signature"); return false;
    }
    const uint32_t pe = pe_rd32(d + 0x3c);
    const uint16_t machine = pe_rd16(d + pe + 4);
    const uint16_t nsec = pe_rd16(d + pe + 6);
    const uint16_t optsz = pe_rd16(d + pe + 20);
    if (pe > n || n - pe < 24 || pe_rd32(d + pe) != 0x00004550u || machine != 0x8664) {
        set_err("M7: not a PE32+ x86-64 image"); return false;
    }
    if (optsz < 112 || (uint64_t)pe + 24 + optsz + (uint64_t)nsec * 40 > n) {
        set_err("M7: truncated optional/section headers"); return false;
    }
    const uint8_t *opt = d + pe + 24;
    const uint32_t ndirs = pe_rd32(opt + 108);
    if (ndirs < 6) { set_err("M7: too few data directories"); return false; }
    const uint8_t *dirs = opt + 112;

    out->image_base = 0;
    for (uint32_t i = 0; i < 8; i++) {
        out->image_base |= (uint64_t)opt[24 + i] << (8 * i);
    }
    out->size_of_image = pe_rd32(opt + 56);
    out->size_of_headers = pe_rd32(opt + 60);
    out->section_count = nsec;
    out->sections = opt + optsz;
    out->export_rva = pe_rd32(dirs + 0);
    out->export_size = pe_rd32(dirs + 4);
    out->reloc_rva = pe_rd32(dirs + 8 * 5);
    out->reloc_size = pe_rd32(dirs + 8 * 5 + 4);
    out->exception_size = pe_rd32(dirs + 8 * 3 + 4);
    if (!out->size_of_image || out->size_of_headers > n ||
        out->size_of_headers > out->size_of_image ||
        out->size_of_image / HUSK_M7_PAGE >= HUSK_M7_MAX_PAGES) {
        set_err("M7: bad image geometry (soi=0x%x sh=0x%x)",
                out->size_of_image, out->size_of_headers);
        return false;
    }
    return true;
}

// stage: HUSK_M7_MAP (M7a, layout only), HUSK_M7_PROTECT (M7b, + real page
// permissions), HUSK_M7_EXEC (M7c, + run real ntdll code), HUSK_M8A_TEB
// (M8a, + a TEB/PEB and the first gs:-relative ntdll call). Keeping one loader
// for all four means the bytes M8a executes are the exact bytes M7a verified.
enum { HUSK_M7_MAP = 0, HUSK_M7_PROTECT = 1, HUSK_M7_EXEC = 2, HUSK_M8A_TEB = 3 };

static int64_t husk_m7_load(const uint8_t *file, size_t n, int stage) {
    HuskM7PE pe{};
    if (!husk_m7_parse(file, n, &pe)) return -41;

    // A wrong image (or a stale expected constant) must fail loudly.
    if (pe.image_base != HUSK_M7_IMAGE_BASE || pe.size_of_image != HUSK_M7_SIZE_IMAGE ||
        pe.section_count != HUSK_M7_SECTIONS) {
        set_err("M7: unexpected PE geometry base=0x%llx soi=0x%x sec=%u",
                (unsigned long long)pe.image_base, pe.size_of_image,
                (unsigned)pe.section_count);
        return -42;
    }

    const size_t map_size =
        (pe.size_of_image + HUSK_M7_PAGE - 1) & ~(size_t)(HUSK_M7_PAGE - 1);
    const uint32_t npages = static_cast<uint32_t>(map_size / HUSK_M7_PAGE);
    HuskM7Mapping map{};
    map.p = ::mmap(nullptr, map_size, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    map.n = map_size;
    if (map.p == MAP_FAILED) { set_err("M7: image mmap failed"); return -43; }
    uint8_t *base = static_cast<uint8_t *>(map.p);

    memcpy(base, file, pe.size_of_headers);
    uint8_t perms[HUSK_M7_MAX_PAGES];
    memset(perms, 0, sizeof(perms));

    uint32_t copied = 0;
    for (uint16_t i = 0; i < pe.section_count; i++) {
        const uint8_t *s = pe.sections + (size_t)i * 40;
        const uint32_t va = pe_rd32(s + 12);
        const uint32_t vsize = pe_rd32(s + 8);
        const uint32_t rawsize = pe_rd32(s + 16);
        const uint32_t raw = pe_rd32(s + 20);
        const uint32_t chars = pe_rd32(s + 36);
        // The permission span is max(VirtualSize, SizeOfRawData) -- NOT the raw
        // size alone. .bss has no file data but 0x109f0 bytes of writable
        // memory, and gating this loop on `rawsize` silently dropped its five
        // RW pages (device trace: rw=1 instead of 6). The copy below is what
        // rawsize actually gates.
        const uint32_t span = vsize > rawsize ? vsize : rawsize;
        if (!span) continue;
        if (rawsize) {
            if ((uint64_t)va + rawsize > pe.size_of_image ||
                (uint64_t)raw + rawsize > n) {
                set_err("M7: section %u out of range (va=0x%x raw=0x%x size=0x%x)",
                        (unsigned)i, va, raw, rawsize);
                return -44;
            }
            memcpy(base + va, file + raw, rawsize);
            copied++;
        }

        // Fold the section's required permissions into every 16 KB page it
        // touches. bit0 = needs X, bit1 = needs W.
        const uint32_t first = va / HUSK_M7_PAGE;
        const uint32_t last = (va + span + HUSK_M7_PAGE - 1) / HUSK_M7_PAGE;
        uint8_t mask = 0;
        if (chars & 0x20000000u) mask |= 1u;  // IMAGE_SCN_MEM_EXECUTE
        if (chars & 0x80000000u) mask |= 2u;  // IMAGE_SCN_MEM_WRITE
        for (uint32_t pg = first; pg < last && pg < HUSK_M7_MAX_PAGES; pg++) {
            perms[pg] |= mask;
        }
    }
    if (copied != pe.section_count - 1) {
        // Exactly one section (.bss) has no raw data in this image.
        set_err("M7: unexpected section-copy count %u", copied);
        return -45;
    }

    uint32_t mixed_pages = 0;
    for (uint32_t pg = 0; pg < map_size / HUSK_M7_PAGE; pg++) {
        if (perms[pg] == 3u) mixed_pages++;
    }
    husk_pe_trace("m7-sections", copied, mixed_pages);

    // ---- base relocations -------------------------------------------------
    // delta is the difference between where the image actually landed and the
    // ImageBase the linker assumed. DIR64 (type 10) entries hold absolute
    // 64-bit pointers that must be rebased; type 0 is alignment padding.
    const uint64_t delta = (uint64_t)base - pe.image_base;
    uint32_t dir64 = 0, pad = 0, blocks = 0;
    uint32_t r = pe.reloc_rva;
    const uint32_t rend = r + pe.reloc_size;
    if (rend > pe.size_of_image) { set_err("M7: reloc directory out of image"); return -46; }
    while (r + 8 <= rend) {
        const uint32_t page = pe_rd32(base + r);
        const uint32_t blocksz = pe_rd32(base + r + 4);
        if (blocksz < 8 || (blocksz & 1) || r + blocksz > rend) {
            set_err("M7: bad reloc block at rva=0x%x size=0x%x", r, blocksz);
            return -47;
        }
        blocks++;
        for (uint32_t j = 8; j + 2 <= blocksz; j += 2) {
            const uint16_t w = pe_rd16(base + r + j);
            const uint16_t type = w >> 12;
            const uint32_t off = page + (w & 0xfffu);
            if (type == 0) { pad++; continue; }
            if (type != 10) {
                set_err("M7: unsupported reloc type %u", (unsigned)type);
                return -48;
            }
            if (off + 8 > pe.size_of_image) {
                set_err("M7: DIR64 target 0x%x outside image", off);
                return -49;
            }
            uint64_t old = 0, fixed = 0;
            memcpy(&old, base + off, 8);
            fixed = old + delta;
            memcpy(base + off, &fixed, 8);
            uint64_t readback = 0;
            memcpy(&readback, base + off, 8);
            if (readback != fixed) {
                set_err("M7: DIR64 write-back mismatch at 0x%x", off);
                return -50;
            }
            dir64++;
        }
        r += blocksz;
    }
    if (dir64 != HUSK_M7_DIR64 || pad != HUSK_M7_RELOC_PAD ||
        blocks != HUSK_M7_RELOC_BLOCKS) {
        set_err("M7: reloc count mismatch dir64=%u pad=%u blocks=%u",
                dir64, pad, blocks);
        return -51;
    }
    husk_pe_trace("m7-reloc", dir64, delta);

    // ---- exports ----------------------------------------------------------
    const uint8_t *ed = base + pe.export_rva;
    const uint32_t nfun = pe_rd32(ed + 20);
    const uint32_t nname = pe_rd32(ed + 24);
    const uint32_t afun = pe_rd32(ed + 28);
    const uint32_t aname = pe_rd32(ed + 32);
    const uint32_t aord = pe_rd32(ed + 36);
    if (nfun != HUSK_M7_EXPORTS || nname != HUSK_M7_EXPORTS) {
        set_err("M7: export count mismatch fun=%u named=%u", nfun, nname);
        return -52;
    }
    uint32_t ldr_rva = 0, disp_rva = 0, hits = 0;
    for (uint32_t i = 0; i < nname; i++) {
        const uint32_t name_rva = pe_rd32(base + aname + 4 * i);
        const uint16_t ord = pe_rd16(base + aord + 2 * i);
        const uint32_t fun_rva = pe_rd32(base + afun + 4 * (uint32_t)ord);
        if (husk_m7_name_eq(base, pe.size_of_image, name_rva, "LdrInitializeThunk")) {
            ldr_rva = fun_rva; hits++;
        } else if (husk_m7_name_eq(base, pe.size_of_image, name_rva,
                                   "__wine_syscall_dispatcher")) {
            disp_rva = fun_rva; hits++;
        }
    }
    if (hits != 2 || ldr_rva != HUSK_M7_LDR_INIT_RVA ||
        disp_rva != HUSK_M7_DISPATCH_RVA) {
        set_err("M7: export lookup mismatch hits=%u ldr=0x%x disp=0x%x",
                hits, ldr_rva, disp_rva);
        return -53;
    }
    husk_pe_trace("m7-exports", nname, ldr_rva);
    husk_pe_trace("m7-exceptions", pe.exception_size / 12, disp_rva);

    fprintf(stderr,
            "[husk-m7] image=%p map=0x%zx delta=0x%llx sections=%u "
            "reloc=%u/%u blocks=%u exports=%u ldr=0x%x disp=0x%x "
            "mixed16k=%u unwind=%u stage=%d\n",
            base, map_size, (unsigned long long)delta, copied, dir64, pad,
            blocks, nname, ldr_rva, disp_rva, mixed_pages,
            pe.exception_size / 12, stage);

    if (stage == HUSK_M7_MAP) {
        fprintf(stderr, "[husk-m7] rc=42\n");
        return 42;
    }

    // A guest entry point needs an executable page, and SizeOfImage leaves
    // 8 KiB of page 271 unused, so that page becomes RX instead of R.
    const bool exec_stage = (stage >= HUSK_M7_EXEC);
    uint64_t teb_addr = 0, peb_addr = 0;
    if (exec_stage) {
        const uint32_t stub_page = HUSK_M7C_STUB_RVA / HUSK_M7_PAGE;
        if (stub_page >= npages) { set_err("M7c: thunk page outside image"); return -55; }
        perms[stub_page] |= 1u;
        if (stage == HUSK_M8A_TEB) {
            if (!husk_m8a_make_teb(&teb_addr, &peb_addr,
                                   reinterpret_cast<uint64_t>(base))) return -58;
            if (!husk_m8a_write_stub(base, map_size, peb_addr,
                                     reinterpret_cast<uint64_t>(base))) return -58;
            husk_pe_trace("m8a-stub", HUSK_M7C_STUB_RVA, 0x47);
            fprintf(stderr,
                    "[husk-m8a] teb=%p peb=%p gs=teb peb_image=0x%llx\n",
                    reinterpret_cast<void *>(teb_addr),
                    reinterpret_cast<void *>(peb_addr),
                    (unsigned long long)reinterpret_cast<uint64_t>(base));
        } else {
            if (!husk_m7c_write_stub(base, map_size)) return -55;
            husk_pe_trace("m7c-stub", HUSK_M7C_STUB_RVA, 0x62);
        }
    }

    HuskM7Prot st{};
    if (!husk_m7_protect(base, map_size, perms, npages, &st)) {
        set_err("M7: page protection failed calls=%u ok=%u fail=%u "
                "verified=%u wx=%u", st.calls, st.ok, st.fail, st.verified, st.wx);
        return -54;
    }
    const uint32_t want_runs = exec_stage ? HUSK_M7C_RUNS : HUSK_M7B_RUNS;
    const uint32_t want_rx = exec_stage ? HUSK_M7C_RX : HUSK_M7B_RX;
    const uint32_t want_r = exec_stage ? HUSK_M7C_R : HUSK_M7B_R;
    fprintf(stderr,
            "[husk-m7b] protect calls=%u ok=%u verified=%u exec_refused=%u "
            "rx=%u rw=%u r=%u wx=%u pages=%u\n",
            st.calls, st.ok, st.verified, st.exec_refused,
            st.rx, st.rw, st.r, st.wx, st.rx + st.rw + st.r);
    // verified==0 means the kernel query itself is unavailable on this build.
    // That is not a misprotection, but it must never read as a pass either --
    // the [husk-m7b] line above reports the real number.
    if (st.ok != want_runs || (st.verified != want_runs && st.verified != 0)) {
        set_err("M7b: %u/%u ranges protected, %u verified",
                st.ok, want_runs, st.verified);
        return -54;
    }
    // If this iOS build refuses PROT_EXEC on anonymous memory, those pages fell
    // back to R -- a different but equally correct page map. Anything else is a
    // real mismatch.
    bool counts_ok;
    if (st.exec_refused == 0) {
        counts_ok = st.rx == want_rx && st.rw == HUSK_M7B_RW && st.r == want_r;
    } else {
        counts_ok = st.rx == 0 && st.rw == HUSK_M7B_RW &&
                    st.r == want_r + want_rx;
    }
    if (!counts_ok) {
        set_err("M7b: page map mismatch rx=%u/%u rw=%u/%u r=%u/%u refused=%u",
                st.rx, want_rx, st.rw, HUSK_M7B_RW, st.r, want_r,
                st.exec_refused);
        return -54;
    }
    if (!exec_stage) {
        fprintf(stderr, "[husk-m7b] rc=42\n");
        return 42;
    }

    // ---- run the guest: M7c/RtlCompareMemory or M8a/RtlGetCurrentPeb ------
    if (!g_ctx) {
        std::lock_guard<std::mutex> lock(g_lock);
        if (!g_ctx) {
            const int64_t initrc = husk_fex_init();
            if (initrc != 0 || !g_ctx) {
                set_err("M7c: FEXCore init failed (rc=%lld)", (long long)initrc);
                return -56;
            }
        }
    }
    g_win_mode = false;   // Linux exit(60) path: the guest exits through us
    g_win_use_ws = false;
    const bool m8a = (stage == HUSK_M8A_TEB);
    const int64_t rc = husk_fex_exec(
        reinterpret_cast<uint64_t>(base) + HUSK_M7C_STUB_RVA,
        reinterpret_cast<uint64_t>(base), map_size, m8a ? teb_addr : 0);
    g_code_base = 0;
    g_code_size = 0;

    if (m8a) {
        // A TEB/PEB that the guest could corrupt would still "work", so verify
        // the canaries the thunk never touches.
        uint64_t tcan = 0, pcan = 0;
        memcpy(&tcan, reinterpret_cast<const void *>(teb_addr + 0xf0), 8);
        memcpy(&pcan, reinterpret_cast<const void *>(peb_addr + 0xf0), 8);
        fprintf(stderr,
                "[husk-m8a] rtlgetcurrentpeb exit=%lld want=42 teb_canary=%s "
                "peb_canary=%s\n",
                (long long)rc,
                tcan == 0x4855534b4d384100ULL ? "ok" : "BAD",
                pcan == 0x4855534b4d384100ULL ? "ok" : "BAD");
        if (rc != 42) {
            // 200 = PEB pointer wrong, 210 = PEB->ImageBaseAddress wrong.
            set_err("M8a: RtlGetCurrentPeb path returned exit=%lld (want 42)",
                    (long long)rc);
            return -59;
        }
        if (tcan != 0x4855534b4d384100ULL || pcan != 0x4855534b4d384100ULL) {
            set_err("M8a: guest scribbled over the TEB/PEB canary");
            return -60;
        }
        fprintf(stderr, "[husk-m8a] rc=42\n");
        return 42;
    }

    fprintf(stderr,
            "[husk-m7c] rtlcompare stub=0x%x target=0x%x exit=%lld want=42\n",
            HUSK_M7C_STUB_RVA, HUSK_M7C_RTLCOMPARE, (long long)rc);
    if (rc != 42) {
        // 100+n / 150+n mean call 1 / call 2 returned n instead of 9 / 16.
        set_err("M7c: real ntdll code returned exit=%lld (want 42)", (long long)rc);
        return -57;
    }
    fprintf(stderr, "[husk-m7c] rc=42\n");
    return 42;
}

static int64_t husk_m7_bundle_probe(int stage) {
    g_err[0] = 0;
    // ntdll.dll is pushed next to the executable by deploy_wine_probe.py;
    // it is deliberately NOT baked into the IPA (4.8 MB of build artefact).
    char path[4096];
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) != 0) {
        set_err("M7: executable path too long"); return -1;
    }
    const char *slash = strrchr(path, '/');
    if (!slash) { set_err("M7: bad executable path"); return -1; }
    const size_t prefix = static_cast<size_t>(slash - path) + 1;
    static const char res[] = "ntdll.dll";
    if (prefix + sizeof(res) > sizeof(path)) {
        set_err("M7: bundle path too long"); return -1;
    }
    memcpy(path + prefix, res, sizeof(res));

    FILE *f = fopen(path, "rb");
    if (!f) { set_err("M7: cannot open %s", path); return -2; }
    if (fseek(f, 0, SEEK_END) != 0) {
        fclose(f); set_err("M7: fseek failed"); return -3;
    }
    const long n = ftell(f);
    if (n <= 0 || n > (16 << 20)) {
        fclose(f); set_err("M7: bad image size %ld", n); return -3;
    }
    rewind(f);
    uint8_t *buf = new uint8_t[(size_t)n];
    const size_t got = fread(buf, 1, (size_t)n, f);
    fclose(f);
    if (got != (size_t)n) {
        delete[] buf;
        set_err("M7: short read (%zu of %ld)", got, n);
        return -4;
    }
    fprintf(stderr, "[husk-m7] bundle image %s (%zu bytes)\n", path, got);
    const int64_t rc = husk_m7_load(buf, got, stage);
    delete[] buf;
    return rc;
}

int64_t husk_m7_probe(void) {
    return husk_m7_bundle_probe(HUSK_M7_MAP);
}

int64_t husk_m7b_probe(void) {
    return husk_m7_bundle_probe(HUSK_M7_PROTECT);
}

int64_t husk_m7c_probe(void) {
    return husk_m7_bundle_probe(HUSK_M7_EXEC);
}

int64_t husk_m8a_probe(void) {
    return husk_m7_bundle_probe(HUSK_M8A_TEB);
}

const char *husk_m7_last_error(void) {
    return g_err[0] ? g_err : nullptr;
}
