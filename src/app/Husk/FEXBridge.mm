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

#ifdef HUSK_SAVED_DEBUG
#define DEBUG HUSK_SAVED_DEBUG
#undef HUSK_SAVED_DEBUG
#endif

// M5 needs NSBundle/NSData to reach the bundled PE image.
#import <Foundation/Foundation.h>

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
    HuskSyscall() { OSABI = FEXCore::HLE::SyscallOSABI::OS_LINUX64; }
    uint64_t HandleSyscall(FEXCore::Core::CpuStateFrame *, FEXCore::HLE::SyscallArguments *args) override {
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
// Probe
// ---------------------------------------------------------------------------
int64_t husk_fex_probe(void) {
    if (g_ready.load(std::memory_order_acquire)) return 0; // already ran
    if (g_cached.load() != -999) return g_cached.load();

    std::lock_guard<std::mutex> lock(g_lock);
    if (g_cached.load() != -999) return g_cached.load();

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

static int64_t husk_fex_run_pe(const uint8_t *file, size_t file_size) {
    // The Swift call site runs this right after husk_fex_probe(), but keep it
    // self-contained so a standalone PE marker also works.
    if (!g_ctx) {
        const int64_t warm = husk_fex_probe();
        if (warm != 42 || !g_ctx) {
            set_err("PE: FEXCore not ready (warm=%lld)", (long long)warm);
            return -20;
        }
    }

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

    uint8_t stub[] = {
        0xE8, 0x00, 0x00, 0x00, 0x00,             // call rel32
        0x89, 0xC7,                               // mov edi, eax
        0xB8, 0x3C, 0x00, 0x00, 0x00,             // mov eax, 60
        0x0F, 0x05                                // syscall
    };
    const int64_t rel = (int64_t)pe.entry_rva - (int64_t)(stub_rva + 5);
    if (rel < -2147483648LL || rel > 2147483647LL) {
        set_err("PE: entry too far from stub"); ::munmap(image, map_size); return -24;
    }
    const int32_t rel32 = static_cast<int32_t>(rel);
    memcpy(stub + 1, &rel32, sizeof(rel32));
    memcpy(base + stub_rva, stub, sizeof(stub));

    const uint64_t image_addr = reinterpret_cast<uint64_t>(image);
    g_code_base = image_addr;   // QueryGuestExecutableRange must cover the PE
    g_code_size = map_size;

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

    auto *thread = g_ctx->CreateThread(image_addr + stub_rva, start_sp);
    if (!thread) {
        set_err("PE: CreateThread null");
        ::munmap(stack, STACK_SIZE); ::munmap(image, map_size);
        return -26;
    }
    {
        constexpr size_t CR = FEXCore::Core::InternalThreadState::CALLRET_STACK_SIZE;
        void *a = ::mmap(nullptr, CR + 2 * PAGE, PROT_NONE,
                         MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (a == MAP_FAILED) {
            set_err("PE: callret mmap failed");
            ::munmap(stack, STACK_SIZE); ::munmap(image, map_size);
            return -27;
        }
        void *crbase = static_cast<uint8_t *>(a) + PAGE;
        ::mprotect(crbase, CR, PROT_READ | PROT_WRITE);
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
    if (setjmp(g_exit_jmp) == 0) {
        g_ctx->ExecuteThread(thread);
        set_err("PE: ExecuteThread returned without exit");
        g_exit_code = -9;
    }
    const int64_t rc = g_exit_code;
    fprintf(stderr,
            "[husk-pe] image=%p map=0x%zx sections=%u entry=0x%x stub=0x%zx exit=%lld\n",
            image, map_size, (unsigned)pe.section_count, pe.entry_rva,
            stub_rva, (long long)rc);

    // No further guest thread will run; stop reporting an unmapped range.
    g_code_base = 0;
    g_code_size = 0;
    ::munmap(stack, STACK_SIZE);
    ::munmap(image, map_size);
    return rc;
}

int64_t husk_pe_probe(void) {
    g_err[0] = 0;
    @autoreleasepool {
        NSString *path = [[NSBundle mainBundle] pathForResource:@"hello" ofType:@"exe"];
        if (!path) { set_err("PE: Resources/hello.exe missing from bundle"); return -1; }
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data || data.length < 0x40) {
            set_err("PE: cannot read %s", path.fileSystemRepresentation);
            return -2;
        }
        fprintf(stderr, "[husk-pe] bundle image %s (%llu bytes)\n",
                path.fileSystemRepresentation, (unsigned long long)data.length);
        return husk_fex_run_pe(static_cast<const uint8_t *>(data.bytes),
                               static_cast<size_t>(data.length));
    }
}

const char *husk_pe_last_error(void) {
    return g_err[0] ? g_err : nullptr;
}
