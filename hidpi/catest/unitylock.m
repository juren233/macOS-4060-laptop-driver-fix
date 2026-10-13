// unitylock: Unity 6 style - the app holds @synchronized(commandBuffer) / @synchronized(queue) around commit + waitUntilCompleted
// (upstream 4f48b3d: the plugin's completion path locked the same objects -> first-frame hang). N cycles, each must finish.
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    @autoreleasepool {
        int n = argc > 1 ? atoi(argv[1]) : 200;
        id<MTLDevice> d = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> q = [d newCommandQueue];
        id<MTLBuffer> b = [d newBufferWithLength:4 options:MTLResourceStorageModeShared];
        __block int handled = 0;
        for (int i = 0; i < n; i++) {
            id<MTLCommandBuffer> cb = [q commandBuffer];
            [cb addCompletedHandler:^(id<MTLCommandBuffer> c) { __atomic_add_fetch(&handled, 1, __ATOMIC_RELAXED); }];
            id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder]; [e fillBuffer:b range:NSMakeRange(0, 4) value:(uint8_t)i]; [e endEncoding];
            @synchronized (q) { @synchronized (cb) { [cb commit]; [cb waitUntilCompleted]; } }
            if (((uint8_t *)b.contents)[0] != (uint8_t)i) { printf("FAIL: cycle %d value %u\n", i, ((uint8_t *)b.contents)[0]); return 1; }
        }
        printf("PASS: %d lock/commit/wait cycles, %d completion handlers\n", n, handled);
    }
    return 0;
}
