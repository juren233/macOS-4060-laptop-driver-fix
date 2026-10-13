// ffsandbox: Firefox GPU-process sandbox probe. usage: ffsandbox [profile.sb appdir]  (ffsandbox-gpu.sb = SandboxPolicyGPU.h + x86_64 addend
// from mozilla-firefox/firefox security/sandbox/mac, 2026-10-13). Optional sandbox with Firefox's own profile, then Metal device + blit readback,
// then a CGL (Apple OpenGL over the Metal plugin, Firefox's WebGL/WebRender path on macOS) clear + readback.
#import <Metal/Metal.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <mach-o/dyld.h>
#include <string.h>
int sandbox_init_with_parameters(const char *profile, uint64_t flags, const char *const parameters[], char **errorbuf);
int main(int argc, char **argv) { setvbuf(stdout, NULL, _IONBF, 0);
    if (argc > 1) {
        FILE *f = fopen(argv[1], "r"); static char prof[65536]; size_t n = fread(prof, 1, sizeof prof - 1, f); prof[n] = 0; fclose(f);
        char app[1024]; snprintf(app, sizeof app, "%s", argv[2]);
        const char *home = getenv("HOME"); char cache[1024]; confstr(_CS_DARWIN_USER_CACHE_DIR, cache, sizeof cache);
        char bid[1100]; snprintf(bid, sizeof bid, "%sorg.mozilla.firefox", cache);
        const char *params[] = { "SHOULD_LOG", "TRUE", "APP_PATH", app, "DARWIN_USER_CACHE_DIR", cache, "BUNDLE_ID_CACHE_DIR", bid,
            "HOME_PATH", home, "MAC_OS_VERSION", "1506", "IS_ROSETTA_TRANSLATED", "FALSE", "ALLOW_REMOTE_APPLE_IMAGEIO", "FALSE", NULL };
        char *err = NULL;
        if (sandbox_init_with_parameters(prof, 0, params, &err)) { printf("sandbox_init failed: %s\n", err); return 2; }
        printf("sandbox: %s applied\n", argv[1]);
        printf("  sysconf PHYS_PAGES %ld\n", sysconf(_SC_PHYS_PAGES)); FILE *t = fopen("/dev/null", "r"); printf("  open /dev/null read: %s\n", t ? "allowed" : "DENIED"); if (t) fclose(t);
    }
    @autoreleasepool {
        NSArray *devs = MTLCopyAllDevices();
        printf("Metal: %lu device(s)%s%s\n", (unsigned long)devs.count, devs.count ? " - " : "", devs.count ? [[devs[0] name] UTF8String] : "");
        if (devs.count) {
            id<MTLDevice> d = devs[0]; id<MTLCommandQueue> q = [d newCommandQueue];
            id<MTLBuffer> b = [d newBufferWithLength:4096 options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder];
            [e fillBuffer:b range:NSMakeRange(0, 4096) value:0x5a]; [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
            printf("  blit fill: status %ld, byte %#x %s\n", (long)cb.status, ((unsigned char *)b.contents)[4095],
                   ((unsigned char *)b.contents)[4095] == 0x5a ? "OK" : "FAILED");
        }
        for (uint32_t i = 0; i < _dyld_image_count(); i++) if (strstr(_dyld_get_image_name(i), "vulkan_nouveau") || strstr(_dyld_get_image_name(i), "vk-")) printf("  ICD loaded: %s\n", _dyld_get_image_name(i));
        CGLPixelFormatAttribute a[] = { kCGLPFAAccelerated, kCGLPFANoRecovery, kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core, 0 };
        CGLPixelFormatObj pf = NULL; GLint npf = 0; CGLError ce = CGLChoosePixelFormat(a, &pf, &npf);
        if (ce || !pf) { printf("GL: no accelerated pixel format (%d)\nFAIL\n", ce); return 1; }
        CGLContextObj ctx = NULL; ce = CGLCreateContext(pf, NULL, &ctx);
        if (ce || !ctx) { printf("GL: context creation failed (%d)\nFAIL\n", ce); return 1; }
        CGLSetCurrentContext(ctx);
        printf("GL: renderer \"%s\"\n", glGetString(GL_RENDERER));
        GLuint fb, rb; glGenFramebuffers(1, &fb); glBindFramebuffer(GL_FRAMEBUFFER, fb);
        glGenRenderbuffers(1, &rb); glBindRenderbuffer(GL_RENDERBUFFER, rb); glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, 64, 64);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
        glViewport(0, 0, 64, 64); glClearColor(1.0f, 0.5f, 0.0f, 1.0f); glClear(GL_COLOR_BUFFER_BIT);
        unsigned char px[4] = {0}; glReadPixels(32, 32, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
        printf("  clear orange -> %d,%d,%d,%d  glError %#x  %s\n", px[0], px[1], px[2], px[3], glGetError(),
               (px[0] > 250 && px[1] > 120 && px[1] < 135 && px[2] < 5) ? "OK" : "WRONG");
        int ok = devs.count && px[0] > 250 && px[1] > 120 && px[1] < 135 && px[2] < 5;
        printf("%s\n", ok ? "PASS" : "FAIL");
        return ok ? 0 : 1;
    }
}
