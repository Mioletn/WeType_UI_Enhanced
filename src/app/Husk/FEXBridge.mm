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

static int64_t husk_fex_run_pe(const uint8_t *file, size_t file_size, bool win_mode) {
    // M6: arm the Windows syscall dispatcher only for the probe that owns this
    // launch's single guest thread. M0/M5 pass false and keep the Linux path.
    g_win_mode = win_mode;
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
    g_code_base = image_addr;   // QueryGuestExecutableRange must cover the PE
    g_code_size = map_size;
    husk_pe_trace(win_mode ? "m6-mapped" : "mapped",
                  image_addr, (uint64_t)stub_len);
    husk_pe_trace("mapped", image_addr, map_size);

    constexpr size_t STACK_SIZE = 0x10000;
    void *stack = ::mmap(nullptr, STACK_SIZE, PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (stack == MAP_FAILED) {
        set_err("PE: stack mmap failed");
        ::munmap(image, map_size);
        return -25;
    }
    uint64_t *sp = reinterpret_cast<uint64_t *>(
        reinterpret_cast<uint64_t>(stack) + STACK_SIZE);
    *(--sp) = 0; // AT_NULL value
    *(--sp) = 0; // AT_NULL type
    *(--sp) = 0; // envp[0]
    *(--sp) = 0; // argv[0]
    *(--sp) = 0; // argc
    const uint64_t start_sp = reinterpret_cast<uint64_t>(sp);

    husk_pe_trace("before-create", image_addr + stub_rva, start_sp);
    auto *thread = g_ctx->CreateThread(image_addr + stub_rva, start_sp);
    husk_pe_trace("after-create", reinterpret_cast<uint64_t>(thread), 0);
    if (!thread) {
        set_err("PE: CreateThread null");
        ::munmap(stack, STACK_SIZE); ::munmap(image, map_size);
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
            ::munmap(stack, STACK_SIZE); ::munmap(image, map_size);
            return -27;
        }
        void *crbase = static_cast<uint8_t *>(a) + PG;
        if (::mprotect(crbase, CR, PROT_READ | PROT_WRITE) != 0) {
            set_err("PE: callret mprotect failed (crbase=%p CR=0x%zx PG=0x%zx)",
                    crbase, CR, PG);
            ::munmap(a, CR + 2 * PG);
            ::munmap(stack, STACK_SIZE); ::munmap(image, map_size);
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

    g_exit_code = -99;
    husk_pe_trace("before-exec", image_addr + stub_rva, 0);
    if (setjmp(g_exit_jmp) == 0) {
        g_ctx->ExecuteThread(thread);
        set_err("PE: ExecuteThread returned without exit");
        g_exit_code = -9;
    }
    const int64_t rc = g_exit_code;
    husk_pe_trace("guest-exit", static_cast<uint64_t>(rc), 0);
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
    }

    g_win_mode = false;
    // No further guest thread will run; stop reporting an unmapped range.
    g_code_base = 0;
    g_code_size = 0;
    ::munmap(stack, STACK_SIZE);
    ::munmap(image, map_size);
    return result;
}

static int64_t husk_bundle_pe_probe(bool win_mode) {
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
            win_mode ? "m6" : "pe", path, got);
    const int64_t rc = husk_fex_run_pe(buf, got, win_mode);
    delete[] buf;
    return rc;
}

int64_t husk_pe_probe(void) {
    return husk_bundle_pe_probe(false);
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
    return husk_bundle_pe_probe(true);
}

const char *husk_m6_last_error(void) {
    return g_err[0] ? g_err : nullptr;
}
