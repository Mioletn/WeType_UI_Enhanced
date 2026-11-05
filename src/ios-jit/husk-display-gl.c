/*
 * Husk: the GL display path.
 *
 * The software path (husk-display.c) takes a CPU framebuffer from QEMU and
 * copies it out. That is why Android ran at 2 frames per second: with no GPU
 * behind virtio-gpu, every pixel was rasterised in software by a CPU that was
 * itself being emulated, so the cost of drawing was paid twice.
 *
 * This path removes the inner cost. virtio-gpu-gl hands virglrenderer the
 * guest's GL commands, virglrenderer executes them against a real context --
 * ANGLE on top of Metal -- and what arrives here is a texture the phone's GPU
 * has already drawn. All that is left is to blit it to the screen.
 *
 * QEMU supplies most of the machinery once CONFIG_OPENGL is on: egl-context.c
 * implements the three context callbacks verbatim, shader.c does the blit, and
 * qemu_egl_init_dpy_cocoa() brings up EGL through ANGLE. This file is the
 * wiring, not the engine.
 */
#include "qemu/osdep.h"
#include "qemu/error-report.h"
#include "qemu/thread.h"
#include "qemu/timer.h"
#include "ui/console.h"
#include "ui/egl-helpers.h"
#include "ui/egl-context.h"
#include "ui/shader.h"
#include "system/system.h"

#include <dlfcn.h>

#include "husk-display-gl.h"
#include "husk-display.h"

static DisplayGLCtx husk_gl_ctx;
static QemuGLShader *husk_gls;
static EGLSurface    husk_surface = EGL_NO_SURFACE;
static EGLContext    husk_context = EGL_NO_CONTEXT;

static egl_fb husk_guest_fb;   /* what the guest drew */

static int  husk_win_w, husk_win_h;
static bool husk_have_scanout;
static bool husk_flip;
static uint64_t husk_gl_frames;

/* The current scanout's Metal texture, when virgl offers one, and the app-side
 * hook that can draw it. See husk_display_gl_set_metal_presenter(). */
static void *husk_metal_tex;
static int   husk_metal_w, husk_metal_h;
static husk_metal_present_fn husk_metal_present;

/*
 * The guest's picture, as plain bytes.
 *
 * This exists because eglSwapBuffers cannot be called from here. It runs on the
 * QEMU main loop with the BQL held, and on this stack it blocks -- a CAMetalLayer
 * that Core Animation is not currently presenting offers no drawable, so the
 * swap waits for one. While it waits, the main loop is not polling, so the
 * virtio-gpu control virtqueue is not drained either, and the guest fills it and
 * wedges:
 *
 *   INFO: task kworker/3:1:57 blocked for more than 120 seconds.
 *   Workqueue: events drm_fb_helper_damage_work
 *    virtio_gpu_queue_fenced_ctrl_buffer
 *    virtio_gpu_cmd_resource_flush
 *
 * That trace is the guest's kernel waiting for a flush command the host never
 * completed. Every frame the guest drew made it worse, which is why the system
 * went quiet about four minutes in and never reached SurfaceFlinger.
 *
 * So the frame is read back instead of being presented. glReadPixels runs
 * against the scanout framebuffer, touches no drawable, and returns in single
 * digit milliseconds at this size. The app then hands the bytes to a UIImageView
 * through the same path the software display already uses -- which is a route
 * that has been known to work on 12.2 all along.
 *
 * Two buffers, because the reader is on the UI thread: the QEMU thread fills
 * the back one with the lock dropped, then swaps pointers under it.
 */
static uint8_t  *husk_cpu_buf[2];
static size_t    husk_cpu_cap;
static uint8_t  *husk_cpu_front;   /* published; what the UI copies from */
static uint8_t  *husk_cpu_back;    /* being filled by the QEMU thread */
static int       husk_cpu_w, husk_cpu_h;
static uint64_t  husk_cpu_seq;
static QemuMutex husk_cpu_lock;
static bool      husk_cpu_lock_ready;
static uint64_t  husk_cpu_frames, husk_cpu_skipped;

/* Read-back rate. A guest flush arrives at well over a hundred hertz and each
 * read-back is a synchronous GPU stall, so the cap is what keeps the main loop
 * available to the virtqueues. Overridable from the app for one profiling run. */
static int husk_cpu_fps = 15;

void husk_display_gl_set_metal_presenter(husk_metal_present_fn fn)
{
    husk_metal_present = fn;
    fprintf(stderr, "[husk-gl] metal presenter %s\n",
            fn ? "registered" : "cleared");
}

/*
 * Defined below, once husk_gl_dcl_ops exists to compare against.
 *
 * This one is not optional, whatever the struct's shape suggests.
 * console_compatible_with() calls it the moment a console has a GL context:
 *
 *   if (console_has_gl(con) &&
 *       !con->gl->ops->dpy_gl_ctx_is_compatible_dcl(con->gl, dcl))
 *
 * -- with no NULL check on the member. Attaching a context whose ops table
 * leaves it unset therefore does not fail a compatibility test, it jumps to
 * address zero inside register_displaychangelistener(). Every other op in this
 * table is guarded at its call site; this one is not.
 */
static bool husk_gl_ctx_is_compatible_dcl(DisplayGLCtx *dgc,
                                          DisplayChangeListener *dcl);

static const DisplayGLCtxOps husk_gl_ctx_ops = {
    .dpy_gl_ctx_is_compatible_dcl = husk_gl_ctx_is_compatible_dcl,
    .dpy_gl_ctx_create        = qemu_egl_create_context,
    .dpy_gl_ctx_destroy       = qemu_egl_destroy_context,
    .dpy_gl_ctx_make_current  = qemu_egl_make_context_current,
};

static void husk_gl_scanout_disable(DisplayChangeListener *dcl)
{
    husk_have_scanout = false;
    husk_metal_tex = NULL;
    egl_fb_destroy(&husk_guest_fb);
}

static void husk_gl_scanout_texture(DisplayChangeListener *dcl,
                                    uint32_t backing_id,
                                    bool backing_y_0_top,
                                    uint32_t backing_width,
                                    uint32_t backing_height,
                                    uint32_t x, uint32_t y,
                                    uint32_t w, uint32_t h,
                                    ScanoutTextureNative native)
{
    /*
     * Passed through, not negated.
     *
     * The reasoning that produced "!backing_y_0_top" was sound and the answer
     * was still wrong: QEMU has two blit paths and they take opposite senses of
     * this flag. gtk-egl.c calls egl_texture_blit() with y0_top directly and
     * egl_fb_blit() with !y0_top. We use the texture path, so it is the
     * un-negated one -- and getting it backwards renders Android upside down,
     * which is exactly what it did.
     */
    /*
     * Say which handle QEMU is offering, not just the GL one.
     *
     * This fork of QEMU carries a ScanoutTextureNative alongside the GL texture
     * id, and when virglrenderer is running on Metal it can hand over the
     * underlying MTLTexture. UTM's own cocoa display prefers that handle and
     * treats the GL id as the fallback -- which is a strong hint that on this
     * stack the GL id is not always the thing holding the guest's pixels. If
     * these logs show a METAL handle, the GL texture we have been blitting from
     * may be an empty sibling of the texture virgl actually renders into.
     */
    /* Only when the shape or the handle kind changes. Android re-sets the
     * scanout constantly -- 655 times in one session -- and each of these is a
     * formatted write to stderr while the BQL is held. */
    static uint32_t last_w, last_h; static int last_native = -1;
    if (backing_width != last_w || backing_height != last_h
        || (int)native.type != last_native) {
        last_w = backing_width; last_h = backing_height;
        last_native = (int)native.type;
    fprintf(stderr, "[husk-gl] scanout_texture: id=%u %ux%u y0top=%d "
                    "native=%s handle=%p\n",
            backing_id, backing_width, backing_height, backing_y_0_top ? 1 : 0,
            native.type == SCANOUT_TEXTURE_NATIVE_TYPE_METAL ? "METAL" :
            native.type == SCANOUT_TEXTURE_NATIVE_TYPE_D3D   ? "D3D"   : "none",
            native.handle);
    }
    husk_flip = backing_y_0_top;
    husk_metal_tex = native.type == SCANOUT_TEXTURE_NATIVE_TYPE_METAL
                   ? native.handle : NULL;
    husk_metal_w = backing_width;
    husk_metal_h = backing_height;
    egl_fb_setup_for_tex(&husk_guest_fb, backing_width, backing_height,
                         backing_id, false);

    /*
     * Give the texture a filter it can actually be sampled with.
     *
     * The blit above no longer samples it, so this is not what makes the
     * picture appear -- but a render target arriving with the default
     * GL_NEAREST_MIPMAP_LINEAR and no mip chain is incomplete, and anything
     * that ever does sample it gets black for its trouble. Costs nothing, and
     * removes the trap rather than stepping around it.
     */
    glBindTexture(GL_TEXTURE_2D, backing_id);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glBindTexture(GL_TEXTURE_2D, 0);

    husk_have_scanout = true;
    {
        GLenum st;
        GLint prev = 0;
        glGetIntegerv(GL_FRAMEBUFFER_BINDING, &prev);
        glBindFramebuffer(GL_FRAMEBUFFER, husk_guest_fb.framebuffer);
        st = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)prev);
        if (st != GL_FRAMEBUFFER_COMPLETE) {
            fprintf(stderr, "[husk-gl] scanout fb NOT COMPLETE: 0x%x\n", st);
        }
    }
}

/*
 * Print a framebuffer as a small picture.
 *
 * Three sampled pixels were not enough. They established that SOME pixel was
 * non-black and nothing else -- not whether Android was drawing a screen or a
 * void, and not whether the blit was landing. A coarse luminance map answers
 * both at a glance, and it costs one read-back per row rather than per cell.
 *
 * GL's origin is bottom-left, so rows are read from the bottom up and printed
 * top-down; what appears in the log is the right way up.
 */
#define HUSK_TW 40
#define HUSK_TH 18

static void husk_gl_thumbnail(const char *what, GLuint fb, int w, int h)
{
    static const char ramp[] = " .:-=+*#%@";
    uint8_t *row;
    GLint prev = 0;

    if (w <= 0 || h <= 0) {
        fprintf(stderr, "[husk-gl] %s: %dx%d, nothing to read\n", what, w, h);
        return;
    }

    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &prev);
    glBindFramebuffer(GL_FRAMEBUFFER, fb);
    row = g_malloc0(4 * (size_t)w);

    fprintf(stderr, "[husk-gl] %s (%dx%d) at frame %llu:\n",
            what, w, h, (unsigned long long)husk_gl_frames);
    for (int gy = 0; gy < HUSK_TH; gy++) {
        char line[HUSK_TW + 1];
        int y = (int)(((double)gy + 0.5) * h / HUSK_TH);
        unsigned long long sum = 0;

        glReadPixels(0, h - 1 - y, w, 1, GL_RGBA, GL_UNSIGNED_BYTE, row);
        for (int gx = 0; gx < HUSK_TW; gx++) {
            int x = (int)(((double)gx + 0.5) * w / HUSK_TW);
            const uint8_t *px = row + 4 * x;
            int lum = (px[0] * 30 + px[1] * 59 + px[2] * 11) / 100;
            sum += lum;
            line[gx] = ramp[lum * 9 / 255];
        }
        line[HUSK_TW] = 0;
        fprintf(stderr, "[husk-gl]   |%s| avg=%02llx\n",
                line, sum / HUSK_TW);
    }

    g_free(row);
    glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)prev);
}

/*
 * Both ends of the blit, so the two can be told apart.
 *
 * If the guest picture is blank, Android is not drawing and no amount of iOS
 * compositing work will help. If the guest picture has content and the window
 * does not, the blit is at fault. If both have content and the screen is still
 * black, the pixels are reaching the layer and the layer is not reaching the
 * screen -- three distinct bugs that until now all looked the same from here.
 */
/*
 * The picture the app will actually draw, straight out of the buffer it reads.
 *
 * This used to sample framebuffer 0, which was the EGL window surface. There is
 * no window surface in the picture any more -- the frame goes back to the CPU
 * instead -- so sampling it would only ever print black and prove nothing.
 */
static void husk_gl_cpu_thumbnail(void)
{
    static const char ramp[] = " .:-=+*#%@";
    uint8_t *p;
    int w, h;

    qemu_mutex_lock(&husk_cpu_lock);
    p = husk_cpu_front;
    w = husk_cpu_w;
    h = husk_cpu_h;
    if (p == NULL || w <= 0 || h <= 0) {
        qemu_mutex_unlock(&husk_cpu_lock);
        fprintf(stderr, "[husk-gl] the cpu frame: nothing read back yet\n");
        return;
    }

    fprintf(stderr, "[husk-gl] the cpu frame (%dx%d) at frame %llu:\n",
            w, h, (unsigned long long)husk_cpu_seq);
    for (int gy = 0; gy < HUSK_TH; gy++) {
        char line[HUSK_TW + 1];
        int y = (int)(((double)gy + 0.5) * h / HUSK_TH);
        unsigned long long sum = 0;

        for (int gx = 0; gx < HUSK_TW; gx++) {
            int x = (int)(((double)gx + 0.5) * w / HUSK_TW);
            const uint8_t *px = p + ((size_t)y * w + x) * 4;
            int lum = (px[0] * 30 + px[1] * 59 + px[2] * 11) / 100;
            sum += lum;
            line[gx] = ramp[lum * 9 / 255];
        }
        line[HUSK_TW] = 0;
        fprintf(stderr, "[husk-gl]   |%s| avg=%02llx\n", line, sum / HUSK_TW);
    }
    qemu_mutex_unlock(&husk_cpu_lock);
}

static void husk_gl_sample(void)
{
    husk_gl_thumbnail("what the guest drew", husk_guest_fb.framebuffer,
                      husk_guest_fb.width, husk_guest_fb.height);
    husk_gl_cpu_thumbnail();
}

/*
 * Read the guest's scanout back into memory.
 *
 * Runs on the QEMU main loop with the BQL held and the context current, so it
 * must not block on anything belonging to Core Animation -- which is the whole
 * point: no drawable is touched here.
 *
 * The rows are flipped in place. GL's origin is bottom-left and a CGImage's is
 * top-left, so without this the picture arrives upside down. It is a straight
 * memcpy per row rather than 600 single-row glReadPixels calls, because each of
 * those carries a full driver round trip.
 */
static bool husk_gl_readback(void)
{
    int w = husk_guest_fb.width;
    int h = husk_guest_fb.height;
    size_t need, stride;
    uint8_t *dst, *tmp;
    GLenum err;

    if (w <= 0 || h <= 0 || husk_guest_fb.framebuffer == 0) {
        return false;
    }

    stride = (size_t)w * 4;
    need = stride * (size_t)h;

    if (need > husk_cpu_cap) {
        uint8_t *a = g_malloc0(need);
        uint8_t *b = g_malloc0(need);

        qemu_mutex_lock(&husk_cpu_lock);
        g_free(husk_cpu_buf[0]);
        g_free(husk_cpu_buf[1]);
        husk_cpu_buf[0] = a;
        husk_cpu_buf[1] = b;
        husk_cpu_cap = need;
        husk_cpu_front = NULL;
        husk_cpu_back = a;
        qemu_mutex_unlock(&husk_cpu_lock);

        fprintf(stderr, "[husk-gl] readback buffers %zu bytes (%dx%d)\n",
                need, w, h);
    }

    dst = husk_cpu_back;
    if (dst == NULL) {
        return false;
    }

    glBindFramebuffer(GL_FRAMEBUFFER, husk_guest_fb.framebuffer);
    glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, dst);
    err = glGetError();
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    if (err != GL_NO_ERROR) {
        static uint64_t complained;
        if (complained++ % 120 == 0) {
            fprintf(stderr, "[husk-gl] readback failed: 0x%x\n", err);
        }
        return false;
    }

    tmp = g_malloc(stride);
    for (int y = 0; y < h / 2; y++) {
        uint8_t *a = dst + (size_t)y * stride;
        uint8_t *b = dst + (size_t)(h - 1 - y) * stride;
        memcpy(tmp, a, stride);
        memcpy(a, b, stride);
        memcpy(b, tmp, stride);
    }
    g_free(tmp);

    /*
     * RGBA in, BGRA out.
     *
     * glReadPixels gives channel order R,G,B,A. Everything downstream was built
     * for virtio-gpu's 2D scanout, which is BGRA in memory, and the app's CGImage
     * is declared premultipliedFirst + byteOrder32Little -- BGRA. Swapping here
     * keeps one pixel layout across both display modes instead of asking the app
     * to know which one it is looking at.
     */
    for (size_t i = 0; i + 3 < need; i += 4) {
        uint8_t t = dst[i];
        dst[i] = dst[i + 2];
        dst[i + 2] = t;
    }

    qemu_mutex_lock(&husk_cpu_lock);
    husk_cpu_front = husk_cpu_back;
    husk_cpu_back = (husk_cpu_back == husk_cpu_buf[0]) ? husk_cpu_buf[1]
                                                       : husk_cpu_buf[0];
    husk_cpu_w = w;
    husk_cpu_h = h;
    husk_cpu_seq++;
    qemu_mutex_unlock(&husk_cpu_lock);

    husk_cpu_frames++;
    return true;
}

static void husk_gl_update(DisplayChangeListener *dcl,
                           uint32_t x, uint32_t y, uint32_t w, uint32_t h)
{
    static int64_t last_ms;
    int64_t now;

    if (!husk_have_scanout) {
        return;
    }

    /*
     * Metal first, when virgl gave us a texture.
     *
     * Everything below this point goes through the GL texture id, and on this
     * stack that id is not ours to read -- the blit fails with
     * GL_INVALID_FRAMEBUFFER_OPERATION every single frame and writes nothing.
     * The GL path stays for scanouts that arrive with no native handle, which
     * is what the firmware console is, and which did render correctly.
     */
    if (husk_metal_tex && husk_metal_present) {
        husk_metal_present(husk_metal_tex, husk_flip ? 1 : 0,
                           husk_metal_w, husk_metal_h);
        husk_gl_frames++;
        return;
    }

    if (husk_surface == EGL_NO_SURFACE || husk_context == EGL_NO_CONTEXT) {
        return;
    }

    /*
     * Rate limit, and the guest is why.
     *
     * A flush arrives per guest frame and the guest draws well over a hundred
     * a second. Every one of those would otherwise cost a synchronous GPU
     * read-back on the thread that also services the virtqueues. Fifteen is
     * enough to watch Android boot and leaves the main loop responsive.
     */
    now = qemu_clock_get_ms(QEMU_CLOCK_REALTIME);
    if (last_ms != 0 && now - last_ms < (1000 / husk_cpu_fps)) {
        husk_cpu_skipped++;
        return;
    }
    last_ms = now;

    if (eglMakeCurrent(qemu_egl_display, husk_surface, husk_surface,
                       husk_context) != EGL_TRUE) {
        static uint64_t complained;
        if (complained++ % 120 == 0) {
            fprintf(stderr, "[husk-gl] eglMakeCurrent failed on the QEMU thread: "
                            "0x%x\n", eglGetError());
        }
        return;
    }

    if (!husk_gl_readback()) {
        return;
    }

    /* The first few frames, then rarely: this is a synchronous read-back and
     * it stalls the pipeline, so it must not be something the frame rate pays
     * for. Rare is enough -- it answers a yes/no question. */
    if (husk_cpu_frames == 1 || husk_cpu_frames == 10
        || husk_cpu_frames == 60 || (husk_cpu_frames % 300) == 0) {
        husk_gl_sample();
    }

    husk_gl_frames++;
}

static void husk_gl_refresh(DisplayChangeListener *dcl)
{
    graphic_hw_update(dcl->con);
}

static const DisplayChangeListenerOps husk_gl_dcl_ops = {
    .dpy_name                = "husk-gl",
    .dpy_refresh             = husk_gl_refresh,
    .dpy_gl_scanout_disable  = husk_gl_scanout_disable,
    .dpy_gl_scanout_texture  = husk_gl_scanout_texture,
    .dpy_gl_update           = husk_gl_update,
};

static DisplayChangeListener husk_gl_dcl = {
    .ops = &husk_gl_dcl_ops,
};

/* Our context belongs to our listener and to no other. */
static bool husk_gl_ctx_is_compatible_dcl(DisplayGLCtx *dgc,
                                          DisplayChangeListener *dcl)
{
    return dcl->ops == &husk_gl_dcl_ops;
}

uint64_t husk_display_gl_frames(void)
{
    return husk_gl_frames;
}

/*
 * The GL-mode half of husk_display_lock_frame(). Same contract: on true the
 * caller holds the lock and must unlock promptly.
 *
 * The lock is held across the caller's copy rather than handed out with a
 * reference count, because the buffer the reader is copying from is also the
 * one the QEMU thread is about to want back. A copy of a phone-sized frame is
 * a millisecond; a reference count would be more machinery than the problem
 * is worth.
 */
bool husk_display_gl_lock_frame(HuskFrameInfo *out)
{
    if (out == NULL || !husk_cpu_lock_ready) {
        return false;
    }
    qemu_mutex_lock(&husk_cpu_lock);
    if (husk_cpu_front == NULL || husk_cpu_w <= 0 || husk_cpu_h <= 0) {
        qemu_mutex_unlock(&husk_cpu_lock);
        return false;
    }
    out->pixels     = husk_cpu_front;
    out->width      = husk_cpu_w;
    out->height     = husk_cpu_h;
    out->stride     = husk_cpu_w * 4;
    out->bpp        = 32;
    out->generation = 1;
    out->sequence   = husk_cpu_seq;
    return true;
}

void husk_display_gl_unlock_frame(void)
{
    if (husk_cpu_lock_ready) {
        qemu_mutex_unlock(&husk_cpu_lock);
    }
}

uint64_t husk_display_gl_cpu_sequence(void)
{
    return husk_cpu_seq;
}

/* How many guest flushes were dropped for rate limiting, and how many frames
 * were actually read back -- the pair says whether the cap is doing anything. */
void husk_display_gl_stats(uint64_t *frames, uint64_t *skipped)
{
    if (frames)  { *frames  = husk_cpu_frames; }
    if (skipped) { *skipped = husk_cpu_skipped; }
}

/*
 * Split in two because of when QEMU needs the answer.
 *
 * virtio-gpu-gl refuses to realize unless display_opengl is already set:
 *
 *   "-device virtio-gpu-gl-pci: The display backend does not have OpenGL
 *    support enabled"
 *
 * and devices are created inside qemu_init(), long before a
 * DisplayChangeListener can be registered. QEMU's own answer is a display
 * backend with an early_init hook, but every one of those is gated on X11,
 * Win32 or GBM -- egl_init() has no Darwin branch at all, so -display
 * egl-headless cannot help here.
 *
 * What actually has to exist that early is only the EGL display and the flag.
 * The surface needs a CAMetalLayer, and that cannot exist yet because the
 * layer comes from UIKit after layout. So this runs before qemu_init(), and
 * husk_display_gl_init() finishes the job afterwards.
 */
bool husk_display_gl_early(void)
{
    /*
     * This sets a flag and does nothing else, deliberately.
     *
     * An earlier version brought EGL up here too and died before returning:
     *
     *   Assertion failed: (mutex->initialized), qemu_mutex_lock_impl, line 95
     *
     * Nothing in QEMU is safe to call before qemu_init(); its locks, logging
     * and RCU machinery do not exist yet. Even error_report() is a trap.
     *
     * Fortunately none of it is needed. virtio_gpu_gl_device_realize() tests
     * exactly one thing -- display_opengl -- and never touches a context, so
     * the flag is the entire requirement at this point in startup. The EGL
     * display, context, surface and listener are all built afterwards in
     * husk_display_gl_init(), which still runs long before the guest issues
     * its first GL command: Android takes tens of seconds to reach graphics.
     *
     * fprintf, not info_report, for the same reason.
     */
    display_opengl = 1;
    fprintf(stderr, "[husk-gl] display_opengl = 1 (before device creation)\n");
    return true;
}

/*
 * Creation runs on the MAIN thread; binding runs on QEMU's.
 *
 * The previous version did everything on the QEMU thread. eglMakeCurrent
 * returned TRUE and glGetString then returned NULL -- which is what ANGLE
 * returns when no context is current, so the two disagreed. The likeliest
 * explanation left is that ANGLE cannot set up a CAMetalLayer surface off the
 * main thread: CALayer is not thread-safe, and the surface came back nominally
 * valid but without working backing.
 *
 * So the display, context and surface are created on the main thread, the
 * context is released there, and the QEMU thread makes it current afterwards.
 * A context may only be current on one thread at a time, hence the release.
 */
bool husk_display_gl_create(void *native_layer, int width, int height)
{
    husk_win_w = width;
    husk_win_h = height;

    fprintf(stderr, "[husk-gl] create: qemu_egl_init_dpy_cocoa\n");
    if (qemu_egl_init_dpy_cocoa(DISPLAY_GL_MODE_ES) < 0) {
        fprintf(stderr, "[husk-gl] qemu_egl_init_dpy_cocoa failed\n");
        return false;
    }

    fprintf(stderr, "[husk-gl] create: eglCreateContext\n");
    husk_context = qemu_egl_init_ctx();
    if (husk_context == EGL_NO_CONTEXT) {
        fprintf(stderr, "[husk-gl] eglCreateContext failed: 0x%x\n", eglGetError());
        return false;
    }

    fprintf(stderr, "[husk-gl] create: eglCreateWindowSurface on the layer\n");
    husk_surface = qemu_egl_init_surface(husk_context,
                                         (EGLNativeWindowType)native_layer);
    if (husk_surface == EGL_NO_SURFACE) {
        fprintf(stderr, "[husk-gl] eglCreateWindowSurface failed: 0x%x\n", eglGetError());
        return false;
    }

    {
        EGLint sw = -1, sh = -1;
        eglQuerySurface(qemu_egl_display, husk_surface, EGL_WIDTH, &sw);
        eglQuerySurface(qemu_egl_display, husk_surface, EGL_HEIGHT, &sh);
        fprintf(stderr, "[husk-gl] create: ANGLE reports the surface is %dx%d "
                        "(we asked for %dx%d)\n", sw, sh, width, height);
    }

    /* qemu_egl_init_ctx() left the context current here. Release it so the
     * QEMU thread can take it. */
    eglMakeCurrent(qemu_egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    fprintf(stderr, "[husk-gl] create: done, context released for the QEMU thread\n");
    return true;
}

/*
 * Answer one question -- is GL usable on this thread? -- without registering
 * anything or changing QEMU's state.
 *
 * Kept separate from bind() because the answer decides which virtio-gpu device
 * the guest gets, and that has to be decided before qemu_init() creates it.
 * Probing through bind() would mean registering a listener for a console that
 * may not exist yet.
 */
bool husk_display_gl_probe(void)
{
    const GLubyte *vendor;
    void *direct;
    const GLubyte *(*gl_get_string)(GLenum);

    if (husk_surface == EGL_NO_SURFACE || husk_context == EGL_NO_CONTEXT) {
        fprintf(stderr, "[husk-gl] probe: nothing was created\n");
        return false;
    }
    if (eglMakeCurrent(qemu_egl_display, husk_surface, husk_surface,
                       husk_context) != EGL_TRUE) {
        fprintf(stderr, "[husk-gl] probe: eglMakeCurrent failed: 0x%x\n", eglGetError());
        return false;
    }

    /*
     * Four answers now, and the fourth is the one that was missing.
     *
     * The previous probe resolved glGetString through eglGetProcAddress,
     * printed the pointer, and then never called it -- it tested dlsym and
     * epoxy instead. Both of those resolved to 0x2be73be5c, an address nowhere
     * near where ANGLE is loaded, so what they called was some other image's
     * symbol of the same name, and of course it returned NULL. The one pointer
     * known to be ANGLE's own was the one never exercised.
     */
    bool via_proc = false;

    fprintf(stderr, "[husk-gl] probe: eglGetCurrentContext=%p (created %p)\n",
            eglGetCurrentContext(), husk_context);
    fprintf(stderr, "[husk-gl] probe: egl vendor=%s version=%s apis=%s\n",
            eglQueryString(qemu_egl_display, EGL_VENDOR),
            eglQueryString(qemu_egl_display, EGL_VERSION),
            eglQueryString(qemu_egl_display, EGL_CLIENT_APIS));

    /* 1. Through EGL's own resolver: this is ANGLE answering about itself. */
    gl_get_string = (const GLubyte *(*)(GLenum))eglGetProcAddress("glGetString");
    fprintf(stderr, "[husk-gl] probe: eglGetProcAddress(glGetString)=%p\n",
            (void *)gl_get_string);
    if (gl_get_string) {
        const GLubyte *v = gl_get_string(GL_VENDOR);
        const GLubyte *r = gl_get_string(GL_RENDERER);
        via_proc = (v != NULL);
        fprintf(stderr, "[husk-gl] probe: VIA eglGetProcAddress vendor=%s renderer=%s\n",
                v ? (const char *)v : "(null)",
                r ? (const char *)r : "(null)");
    }

    /* 2. By name, which is what epoxy ends up doing, and which finds the
     *    wrong image. Kept so the two can be compared in one log. */
    direct = dlsym(RTLD_DEFAULT, "GL_GetString");
    fprintf(stderr, "[husk-gl] probe: dlsym(GL_GetString)=%p%s\n", direct,
            direct ? "" : " (not found)");

    /* 3. Epoxy's dispatch, which is what virglrenderer will actually use. */
    vendor = glGetString(GL_VENDOR);
    fprintf(stderr, "[husk-gl] probe: epoxy vendor=%s renderer=%s\n",
            vendor ? (const char *)vendor : "(null)",
            (const char *)glGetString(GL_RENDERER));

    fprintf(stderr, "[husk-gl] probe: VERDICT angle=%s epoxy=%s\n",
            via_proc ? "WORKS" : "no", vendor ? "WORKS" : "no");

    return vendor != NULL;
}

bool husk_display_gl_bind(void)
{
    QemuConsole *con;
    const GLubyte *vendor;

    /*
     * Safe here and nowhere earlier: QEMU's mutexes do not exist before
     * qemu_init(), and bind() runs after it.
     */
    if (!husk_cpu_lock_ready) {
        qemu_mutex_init(&husk_cpu_lock);
        husk_cpu_lock_ready = true;
    }

    if (husk_surface == EGL_NO_SURFACE || husk_context == EGL_NO_CONTEXT) {
        fprintf(stderr, "[husk-gl] bind: nothing was created\n");
        return false;
    }

    fprintf(stderr, "[husk-gl] bind: eglMakeCurrent\n");
    if (eglMakeCurrent(qemu_egl_display, husk_surface, husk_surface,
                       husk_context) != EGL_TRUE) {
        fprintf(stderr, "[husk-gl] eglMakeCurrent failed: 0x%x\n", eglGetError());
        return false;
    }

    vendor = glGetString(GL_VENDOR);
    fprintf(stderr, "[husk-gl] bind: GL_VENDOR=%s GL_RENDERER=%s GL_VERSION=%s\n",
            vendor ? (const char *)vendor : "(null)",
            (const char *)glGetString(GL_RENDERER),
            (const char *)glGetString(GL_VERSION));

    /* No usable dispatch means no shaders. Compiling them anyway is what
     * segfaulted before, calling through a pointer resolution never produced. */
    if (!vendor) {
        fprintf(stderr, "[husk-gl] GL dispatch unusable; falling back to software\n");
        return false;
    }

    /*
     * Preflight the entry points the shader path needs.
     *
     * qemu_gl_init_shader() compiles and links, and every GL call it makes goes
     * through epoxy's dispatch. An entry point epoxy cannot resolve arrives
     * there as a NULL function pointer and is called anyway -- which is a
     * SIGSEGV with nothing in the log but the line before it. Checking first
     * turns that into a named symbol and a fallback to the software display,
     * which is slow but alive.
     */
    {
        static const char *const needed[] = {
            "glCreateShader", "glShaderSource", "glCompileShader",
            "glGetShaderiv", "glGetShaderInfoLog", "glCreateProgram",
            "glAttachShader", "glLinkProgram", "glGetProgramiv",
            "glGetProgramInfoLog", "glDeleteShader", "glUseProgram",
            "glGenVertexArrays", "glBindVertexArray", "glGenBuffers",
            "glBindBuffer", "glBufferData", "glVertexAttribPointer",
            "glEnableVertexAttribArray", "glGetAttribLocation",
            "glGetUniformLocation", "glUniform1i", "glActiveTexture",
            "glBindTexture", "glDrawArrays", "glViewport", "glClear",
            "glClearColor",
            /* egl_fb_setup_for_tex() and egl_texture_blit() reach for these,
             * and the first list forgot all of them. */
            "glGenFramebuffers", "glBindFramebuffer", "glFramebufferTexture2D",
            "glDeleteFramebuffers", "glDeleteTextures", "glGenTextures",
            "glTexParameteri", "glTexImage2D", "glBlitFramebuffer",
            "glCheckFramebufferStatus", "glDisable", "glGetError",
            "glReadPixels", "glColorMask", "glGetIntegerv",
            "glBlitFramebuffer", "glTexParameteri", "glBindTexture",
        };
        bool missing = false;
        for (size_t i = 0; i < ARRAY_SIZE(needed); i++) {
            if (!eglGetProcAddress(needed[i])) {
                fprintf(stderr, "[husk-gl] missing entry point: %s\n", needed[i]);
                missing = true;
            }
        }
        if (missing) {
            fprintf(stderr, "[husk-gl] GL is incomplete; using the software "
                            "display rather than crashing in the shader\n");
            return false;
        }
        fprintf(stderr, "[husk-gl] all %zu shader entry points resolve\n",
                ARRAY_SIZE(needed));
    }

    husk_gls = qemu_gl_init_shader();
    if (!husk_gls) {
        fprintf(stderr, "[husk-gl] shader init failed\n");
        return false;
    }

    husk_gl_ctx.ops = &husk_gl_ctx_ops;

    fprintf(stderr, "[husk-gl] bind: qemu_console_lookup_by_index(0)\n");
    con = qemu_console_lookup_by_index(0);
    if (!con) {
        fprintf(stderr, "[husk-gl] no console 0\n");
        return false;
    }
    /*
     * console_compatible_with() reaches straight through con->hw_ops without
     * checking it, so a console that is not a graphics console segfaults inside
     * registration rather than being rejected. Report what we got before
     * handing it over.
     */
    fprintf(stderr, "[husk-gl] bind: console=%p graphic=%d gl_block=%d\n",
            (void *)con, qemu_console_is_graphic(con) ? 1 : 0, 0);

    husk_gl_dcl.con = con;
    fprintf(stderr, "[husk-gl] bind: qemu_console_set_display_gl_ctx\n");
    qemu_console_set_display_gl_ctx(con, &husk_gl_ctx);
    fprintf(stderr, "[husk-gl] bind: register_displaychangelistener\n");
    register_displaychangelistener(&husk_gl_dcl);
    fprintf(stderr, "[husk-gl] bind: listener registered\n");

    fprintf(stderr, "[husk-gl] GL display up: %dx%d\n", husk_win_w, husk_win_h);
    return true;
}
