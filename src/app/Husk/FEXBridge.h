/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Husk -- FEXCore probe, the first step of the Madeira-lite path.
 *
 * FEXCore translates x86/x86-64 user-space code to ARM64 at run time. The
 * question this answers, before any Wine work, is whether it can be built for
 * and execute code on iOS 12.2 at all.
 *
 * husk_fex_probe() runs a 53-byte self-checking x86-64 program through
 * FEXCore on a dual-mapped JIT region taken from husk-ios-jit.c:
 *
 *     sum = 1+2+...+1000
 *     if (sum != 500500) exit(1);
 *     else exit(get42());          // call/ret through the call-ret stack
 *
 * It returns 42 when decoding, JIT codegen, the loop, the branch, the shadow
 * call stack, the syscall hook and the exit path all work; a negative value
 * means setup failed (the reason is logged).
 *
 * It is deliberately gated behind a marker file (Documents/husk-fex-probe) so
 * it never touches the JIT region on a normal boot: the naive path below sets
 * DualMap::WriteOffset to 0, which is only valid while the region is RWX.
 */
#ifndef HUSK_FEX_BRIDGE_H
#define HUSK_FEX_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Returns the guest exit status (42 on success), or negative on failure. */
int64_t husk_fex_probe(void);

/* Human-readable reason for the last failure, or NULL. */
const char *husk_fex_last_error(void);

/* M5: map the bundled minimal PE32+ (Resources/hello.exe) into the FEX guest
 * address space and execute its entry point through FEXCore. hello.exe is
 * freestanding: its entry is `mov eax,42; ret`, with no imports referenced and
 * no base relocations. Returns the guest exit() status (42 on success), or a
 * negative setup error. Safe to call after husk_fex_probe(); if the FEX context
 * has not been created yet it initialises one itself. */
int64_t husk_pe_probe(void);

/* Human-readable reason for the last PE failure, or NULL. */
const char *husk_pe_last_error(void);

/* M6: run the SAME bundled PE, but with the Windows x64 syscall ABI.
 *
 * The appended stub calls the real PE entry, then makes four consecutive
 * Windows syscalls in Wine's own stub form (mov r10,rcx; mov eax,<id>;
 * syscall): NtClose(15), NtQueryInformationProcess(25), NtCreateFile(85),
 * NtTerminateProcess(44). HuskSyscall dispatches them through the generated
 * 258-entry id table in HuskWinSyscalls.h, returns NTSTATUS in RAX and lets
 * the guest resume after each one. Returns 42 only if all four syscalls were
 * seen in order with correct Windows ABI arguments, NTSTATUS was written
 * back, and the guest exited with 42. Negative on setup/dispatch failure.
 *
 * Like the PE probe this owns the launch's ONE guest thread; arm it with the
 * Documents/husk-m6-probe marker instead of husk-pe-probe. */
int64_t husk_m6_probe(void);

/* M6b: same guest program and the same four Windows syscalls, but
 * NtQueryInformationProcess is forwarded to the in-process wineserver as a
 * real REQ_get_process_info request and the server's NTSTATUS is returned to
 * the guest. Requires husk_ws_start() to have run first in this launch; the
 * husk-m6b-probe marker does that in Swift. Returns 42 only when the server
 * round trip completed AND all four syscalls passed their checks. */
int64_t husk_m6b_probe(void);

/* Human-readable reason for the last M6 failure, or NULL. */
const char *husk_m6_last_error(void);

/* M7a: lay out the REAL Wine ntdll.dll in this process -- copy all 19
 * sections, apply its 192 base relocations, resolve its 1466 named exports
 * and report 16 KB page-permission conflicts. This is a pure host-side PE
 * loader probe: it creates NO FEXCore guest thread and needs no TEB/PEB, so
 * it cannot regress the M0-M6b probes. ntdll.dll is pushed next to the
 * executable by deploy_wine_probe.py, not baked into the IPA. Returns 42 on
 * success, a negative setup/parse error otherwise. */
int64_t husk_m7_probe(void);

/* Human-readable reason for the last M7 failure, or NULL. */
const char *husk_m7_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* HUSK_FEX_BRIDGE_H */
