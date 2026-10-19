// glvsync: frames per second of a vsync'd OpenGL window, the way a game or Steam's UI presents (NSOpenGLContext with swap
// interval 1, flushBuffer per frame). Every 40th frame is made late on purpose (sleep 1.5 refresh periods): AppKit's own
// NSCGLSurface synchronize then waits by 1/60 s steps and keeps the app at two to three refreshes a frame on a faster
// display; with NullMoth 2.3.6's GL vblank correction a late frame costs one refresh. A 320x200 window shows for ~6 s.
// Prints: display Hz, frames/s, and the share of frame intervals longer than 1.5 periods; last line "glvsync: <fps> fps".
//   clang -fobjc-arc -O2 -o glvsync glvsync.m -framework AppKit -framework OpenGL -framework CoreVideo
#define GL_SILENCE_DEPRECATION
#import <AppKit/AppKit.h>
#import <OpenGL/gl3.h>
#include <mach/mach_time.h>

static double now_s(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9; }

int main(int argc, const char **argv) {
    @autoreleasepool {
        double secs = argc > 1 ? atof(argv[1]) : 5;
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(80, 80, 320, 200) styleMask:NSWindowStyleMaskTitled
                                                    backing:NSBackingStoreBuffered defer:NO];
        w.title = @"glvsync"; w.releasedWhenClosed = NO;
        NSOpenGLPixelFormatAttribute attrs[] = { NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersion4_1Core, NSOpenGLPFADoubleBuffer, NSOpenGLPFAAccelerated, 0 };
        NSOpenGLPixelFormat *pf = [[NSOpenGLPixelFormat alloc] initWithAttributes:attrs];
        NSOpenGLView *v = [[NSOpenGLView alloc] initWithFrame:NSMakeRect(0, 0, 320, 200) pixelFormat:pf];
        v.wantsBestResolutionOpenGLSurface = YES;
        w.contentView = v; [w makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
        NSOpenGLContext *ctx = v.openGLContext; [ctx makeCurrentContext];
        GLint one = 1; [ctx setValues:&one forParameter:NSOpenGLContextParameterSwapInterval];
        double hz = w.screen.maximumFramesPerSecond ?: 60, period = 1.0 / hz;
        __block unsigned frames = 0, slow = 0; __block double start = 0, last = 0;
        [NSApp finishLaunching];
        [NSTimer scheduledTimerWithTimeInterval:0 repeats:YES block:^(NSTimer *timer) {
            if (!start) { start = last = now_s() + 0.5; return; }          // let the window reach the screen first
            if (now_s() < start) return;
            float c = (frames % 2) ? 0.2f : 0.4f;
            glClearColor(c, 0.3f, 0.5f, 1); glClear(GL_COLOR_BUFFER_BIT);
            if (frames % 40 == 39) usleep((useconds_t)(period * 1.5e6));   // a late frame
            if (frames < 3) fprintf(stderr, "flush %u (window visible %d)\n", frames, (int)((w.occlusionState & NSWindowOcclusionStateVisible) != 0));
            [ctx flushBuffer];
            if (frames < 3) fprintf(stderr, "flushed %u\n", frames);
            double t = now_s(); if (frames && t - last > 1.5 * period) slow++; last = t; frames++;
            if (t - start >= secs) { [timer invalidate]; [NSApp stop:nil];
                [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0
                    timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:NO]; }
        }];
        [NSApp run];
        double el = now_s() - start;
        printf("display %.0f Hz, %u frames in %.2f s = %.1f fps (%.2f refreshes per frame), %.1f%% of intervals > 1.5 periods\n",
               hz, frames, el, frames / el, hz / (frames / el), 100.0 * slow / (frames > 1 ? frames - 1 : 1));
        printf("glvsync: %.1f fps\n", frames / el);
        [w orderOut:nil];
    }
    return 0;
}
