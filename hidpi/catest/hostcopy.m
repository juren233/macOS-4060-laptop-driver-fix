// hostcopy: a no-copy buffer over the caller's memory that the driver could not import (so it keeps a copy), with a
// texture made over it, sampled after the caller rewrites the memory -- what Core Animation does with small
// shared-memory layer contents. Prints whether the GPU sees the new bytes.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <sys/mman.h>
int main(void) { @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> q = [dev newCommandQueue];
    const int W = 64, H = 16; const NSUInteger bpr = 256, len = bpr * H + 100;   // length not page-sized: import refused -> copy
    uint8_t *mem = mmap(NULL, 16384, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    memset(mem, 0x40, len);
    id<MTLBuffer> buf = [dev newBufferWithBytesNoCopy:mem length:len options:MTLResourceStorageModeShared deallocator:nil];
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [buf newTextureWithDescriptor:d offset:0 bytesPerRow:bpr];
    if (!t) { printf("no texture\n"); return 2; }
    // Sample through a draw (a render pass reading the texture), like a compositor does.
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct V { float4 p [[position]]; };\n"
        "vertex V vs(uint i [[vertex_id]]) { float2 c[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) }; V o; o.p = float4(c[i], 0, 1); return o; }\n"
        "fragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]]) { return t.read(uint2(in.p.xy) % uint2(64, 16)); }\n";
    NSError *e = nil; id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&e];
    if (!lib) { printf("library: %s\n", e.description.UTF8String); return 2; }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vs"]; pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!ps) { printf("pipeline: %s\n", e.description.UTF8String); return 2; }
    MTLTextureDescriptor *od = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
    od.storageMode = MTLStorageModeShared; od.usage = MTLTextureUsageRenderTarget;
    int fails = 0;
    for (int step = 0; step < 4; step++) {
        const uint8_t v = (uint8_t)(0x80 + step * 0x20);
        memset(mem, v, len);                                   // the caller rewrites its memory
        id<MTLTexture> o = [dev newTextureWithDescriptor:od];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = o; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
        [re setRenderPipelineState:ps]; [re setFragmentTexture:t atIndex:0]; [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [re endEncoding]; [cb commit]; [cb waitUntilCompleted];
        uint8_t p[4]; [o getBytes:p bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(W / 2, H / 2, 1, 1) mipmapLevel:0];
        printf("step %d: wrote 0x%02x, GPU sees 0x%02x %s | memory now 0x%02x\n", step, v, p[0], p[0] == v ? "ok" : "STALE", mem[bpr * 8 + 128]);
        if (p[0] != v) fails++;
    }
    printf("stale reads: %d\n", fails);
    return fails != 0;
}}
