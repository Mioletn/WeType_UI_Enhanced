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

#ifdef __cplusplus
}
#endif

#endif /* HUSK_FEX_BRIDGE_H */
