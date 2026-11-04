/*
 * What the screen is made of, asked of the layer this engine renders into.
 *
 * A frame can be drawn, uploaded, swapped, and still never be seen: Core Animation shows nothing for a layer
 * that is not in a window, that is hidden, that sits outside its parent, or whose drawable does not match the
 * surface, and it reports none of it -- the frame counter looks healthy while the screen is black. These
 * answers are the difference between a picture that never arrived and one that arrived into something nobody
 * can see.
 *
 * The second line is the chain of layers above this one, because a layer of the right size can still be parked
 * outside a parent of the wrong one, and nothing about the layer itself says so. It ends at the window, which
 * is the only thing that says whether any of it is being shown at all.
 */
#include <TargetConditionals.h>
#include <stddef.h>
#include <stdio.h>

#if TARGET_OS_IPHONE
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#endif

const char *husk_layer_describe(void *p, char *out, size_t n)
{
    if (!out || !n) return "";
#if TARGET_OS_IPHONE
    CALayer *l = (__bridge CALayer *)p;
    if (!l) { snprintf(out, n, "layer: none (the engine was given no surface)"); return out; }
    CGSize ds = CGSizeZero; int fbOnly = -1, pwt = -1, drawsAsync = -1;
    if ([l isKindOfClass:[CAMetalLayer class]]) {
        CAMetalLayer *m = (CAMetalLayer *)l;
        ds = m.drawableSize;
        fbOnly = m.framebufferOnly ? 1 : 0;
        pwt = m.presentsWithTransaction ? 1 : 0;
        drawsAsync = m.drawsAsynchronously ? 1 : 0;
    }
    /* CALayer has no window of its own on iOS: the one it is in is found through the layer's owner, the UIView, which is the
       layer's delegate -- and a layer whose chain reaches no view at all is a layer nothing can display. */
    UIWindow *win = nil;
    for (CALayer *c = l; c && !win; c = c.superlayer) {
        id owner = c.delegate;
        if ([owner isKindOfClass:[UIView class]]) win = ((UIView *)owner).window;
    }
    CGRect f = l.frame;
    CATransform3D t = l.transform;
    size_t used = (size_t)snprintf(out, n,
             "layer %p: bounds %.0fx%.0f @%.0f,%.0f scale %.2f drawable %.0fx%.0f | frame (%.0f,%.0f %.0fx%.0f) "
             "xform (%.2f,%.2f,%.2f,%.2f) | hidden %d opacity %.2f opaque %d | fbOnly %d pwt %d async %d | "
             "superlayer %p window %p%s",
             (__bridge void *)l, (double)l.bounds.size.width, (double)l.bounds.size.height,
             (double)l.bounds.origin.x, (double)l.bounds.origin.y, (double)l.contentsScale,
             (double)ds.width, (double)ds.height,
             (double)f.origin.x, (double)f.origin.y, (double)f.size.width, (double)f.size.height,
             (double)t.m11, (double)t.m12, (double)t.m21, (double)t.m22,
             (int)l.hidden, (double)l.opacity, (int)l.isOpaque,
             fbOnly, pwt, drawsAsync, (__bridge void *)l.superlayer, (__bridge void *)win,
             win ? (win.isKeyWindow ? " key" : " notKey") : "");
    if (used > n) used = n;
    if (used < n) used += (size_t)snprintf(out + used, n - used, "\n  chain:");
    if (used > n) used = n;
    /* Eight layers is deeper than UIKit ever goes, and the window is the end of the chain anyway. */
    for (CALayer *c = l; c && used + 80 < n; c = c.superlayer) {
        const char *cls = class_getName(object_getClass(c));
        UIView *owner = nil;
        if ([c.delegate isKindOfClass:[UIView class]]) owner = (UIView *)c.delegate;
        size_t got = (size_t)snprintf(out + used, n - used, " %s%s %.0fx%.0f@(%.0f,%.0f) h%d o%.2f",
                                      c == l ? "" : "<- ", cls ? cls : "?",
                                      (double)c.bounds.size.width, (double)c.bounds.size.height,
                                      (double)c.frame.origin.x, (double)c.frame.origin.y,
                                      (int)c.hidden, (double)c.opacity);
        used += got; if (used > n) used = n;
        if (owner && used + 96 < n) {
            const char *vc = class_getName(object_getClass(owner));
            got = (size_t)snprintf(out + used, n - used, " [view %s]", vc ? vc : "?");
            used += got; if (used > n) used = n;
        }
        if ([c isKindOfClass:[UIWindow class]]) {
            UIWindow *w = (UIWindow *)c;
            const char *rc = w.rootViewController ? class_getName(object_getClass(w.rootViewController)) : "none";
            if (used + 176 < n) {
                got = (size_t)snprintf(out + used, n - used, " key%d lvl%.0f a%.2f hidden%d root=%s",
                                       w.isKeyWindow ? 1 : 0, (double)w.windowLevel, (double)w.alpha,
                                       w.hidden ? 1 : 0, rc ? rc : "?");
                used += got; if (used > n) used = n;
            }
            break;   /* the window is the top of the chain */
        }
    }
#else
    (void)p;
    snprintf(out, n, "layer: iOS only");
#endif
    return out;
}
