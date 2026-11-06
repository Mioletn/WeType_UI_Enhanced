/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Husk -- FEXCore probe, the first step of the Madeira-lite path.
 *
 * FEXCore translates x86/x86-64 user-space code to ARM64 at run time. The
 * question this answers, before any Wine work, is whether it can be built for
 * and execute code on iOS 12.2 at all.
 *
 * husk_fex_probe() runs a six-byte x86-64 program:
 *
 *     mov eax, 60      ; exit(2) syscall number
 *     mov edi, 42      ; status
 *     syscall
 *
 * through FEXCore on a dual-mapped JIT region taken from husk-ios-jit.c. It
 * returns 42 when translation, execution, the syscall hook and the exit path
 * all work; a negative value means setup failed (the reason is logged).
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

#ifdef __cplusplus
}
#endif

#endif /* HUSK_FEX_BRIDGE_H */
