//
//  HuskSelectorLog.m
//  Husk
//
//  Names the selector that killed the run.
//
//  Two crashes in a row (an ANGLE Metal capability probe, then a property on
//  MTLCompileOptions) ended as "abort() called" with nothing else: an
//  unrecognized selector raises NSInvalidArgumentException, C++ unwinding finds
//  no handler on a runtime thread, std::terminate calls abort, and the only
//  record of which message was sent lives in the .ips, which has to be pulled
//  off the device to read. Both times the culprit turned out to be a Metal API
//  newer than iOS 12.2, and both times finding out cost a build round.
//
//  This swizzles -[NSObject doesNotRecognizeSelector:] -- the last stop before
//  the exception is raised -- and writes one line to the run log, the screen
//  that is already open when a run dies. Behaviour is unchanged: the original
//  implementation still runs, so the process aborts exactly as before; the
//  difference is that the console now says
//
//      crash: unrecognized selector -[MTLCompileOptions setPreserveInvariance:]
//
//  instead of stopping mid-run. Coupled through husk_tl_note() rather than
//  HuskLog for that reason: the run screen reads the translation layer's log,
//  not the app's own.
//

#import <Foundation/Foundation.h>
#include <objc/runtime.h>
#include <stdio.h>

extern void husk_tl_note(const char *text);

static IMP huskOriginalDoesNotRecognizeSelector = NULL;
static int huskSelectorNotesWritten = 0;

static void huskNoteUnrecognizedSelector(id self, SEL _cmd, SEL selector)
{
    // A handful, then quiet: a run that walks off a table of selectors would
    // otherwise spend its last milliseconds filling the log with the same line.
    if (huskSelectorNotesWritten < 8)
    {
        char line[256];
        const char *name = selector ? sel_getName(selector) : "(null)";
        huskSelectorNotesWritten++;
        snprintf(line, sizeof line, "crash: unrecognized selector -[%s %s]",
                 object_getClassName(self), name);
        husk_tl_note(line);
        NSLog(@"%s", line);
    }

    if (huskOriginalDoesNotRecognizeSelector != NULL)
    {
        ((void (*)(id, SEL, SEL))huskOriginalDoesNotRecognizeSelector)(self, _cmd, selector);
    }
}

__attribute__((constructor)) static void huskInstallSelectorLog(void)
{
    Method method = class_getInstanceMethod([NSObject class],
                                            sel_registerName("doesNotRecognizeSelector:"));
    if (method != NULL)
    {
        huskOriginalDoesNotRecognizeSelector = method_setImplementation(
            method, (IMP)huskNoteUnrecognizedSelector);
    }
}
