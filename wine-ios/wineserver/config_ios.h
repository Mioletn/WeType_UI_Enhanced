// Include the macOS-generated config.h first
#include "config.h"

// Override settings that differ on iOS
#undef HAVE_SYS_USER_H
#undef HAVE_SYS_PTRACE_H
#undef HAVE_NETINET_TCP_FSM_H

// NO "#define WINE_IOS 1" here on purpose.
//
// This fork's server/*.c has 33 #ifdef WINE_IOS blocks that call helpers living
// only in Madeira's private tree (ios_fill_thread_context, ios_apply_resume_context,
// ios_thread_mach_hold/release, ios_pending_persistent_hold, madsync_post). With
// WINE_IOS on, server/thread.c compiles but the archive cannot link.
//
// Madeira never hit this because their wineserver linked a thread.o from a base
// archive built WITHOUT WINE_IOS; they only compiled their own *_ios shims with
// it. Building the stock TUs without it puts us in the same place: generic Unix
// thread suspension instead of the iOS mach-hold path, which is what a smoke
// test needs anyway.
