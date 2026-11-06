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
