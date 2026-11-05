#ifndef HUSK_DISPLAY_GL_H
#define HUSK_DISPLAY_GL_H

#include <stdbool.h>
#include <stdint.h>

#include "husk-display.h"

/*
 * Bring up the GL display path against a CAMetalLayer. Must be called on the
 * QEMU thread after qemu_init(), and instead of husk_display_init() -- the two
 * register competing DisplayChangeListeners for the same console.
 */
/*
 * Must be called BEFORE qemu_init(). Brings up EGL and sets display_opengl, so
 * virtio-gpu-gl is allowed to realize -- devices are created inside qemu_init(),
 * before any DisplayChangeListener can exist.
 */
bool husk_display_gl_early(void);

/* Create the EGL display, context and surface. MAIN THREAD only: ANGLE is
   setting up a CAMetalLayer, and CALayer is not thread-safe. */
bool husk_display_gl_create(void *native_layer, int width, int height);

/* Make the context current and register the listener. QEMU thread. */
/* Is GL usable here? Registers nothing. */
bool husk_display_gl_probe(void);
bool husk_display_gl_bind(void);

/* Frames presented, for the perf counter. */
uint64_t husk_display_gl_frames(void);

/*
 * Borrow the guest's frame as plain RGBA bytes, top row first.
 *
 * The GL path does not present through an EGL window surface: swapping one from
 * the QEMU thread blocks on a drawable Core Animation is not currently driving,
 * which wedges the main loop and with it the virtio-gpu control queue. The frame
 * is read back to memory instead, and this is how the app collects it.
 *
 * Same contract as husk_display_lock_frame(): on true the caller holds the lock
 * and must call husk_display_gl_unlock_frame() after copying.
 */
bool husk_display_gl_lock_frame(HuskFrameInfo *out);
void husk_display_gl_unlock_frame(void);

/* Bumps once per read-back; cheaper than comparing pixels. */
uint64_t husk_display_gl_cpu_sequence(void);

/* frames read back / guest flushes dropped by the rate limit. */
void husk_display_gl_stats(uint64_t *frames, uint64_t *skipped);

/*
 * Present the guest's scanout directly from its Metal texture.
 *
 * virglrenderer runs on ANGLE-over-Metal here, and the GL texture id it reports
 * alongside each scanout is not readable from our context: blitting from it
 * raises GL_INVALID_FRAMEBUFFER_OPERATION on every frame and produces a blank
 * picture, while Android is demonstrably drawing at forty frames a second. The
 * pixels live in the MTLTexture that this fork of QEMU passes as the scanout's
 * native handle -- which is why UTM's own display uses that handle and treats
 * the GL id as a fallback.
 *
 * `texture` is an id<MTLTexture>, valid for the duration of the call. `flip` is
 * the guest's y_0_top. The implementation lives in the app, because the
 * CAMetalLayer does, so the C side calls out through this hook rather than
 * reaching for UIKit from inside QEMU.
 */
typedef void (*husk_metal_present_fn)(void *texture, int flip,
                                      int width, int height);
void husk_display_gl_set_metal_presenter(husk_metal_present_fn fn);

#endif
