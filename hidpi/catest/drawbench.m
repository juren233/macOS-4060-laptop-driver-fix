// drawbench: CPU cost per draw of the plugin's render encoder, the way ANGLE drives it for many small objects (WebGL aquarium:
// one draw per fish, only per-object uniforms change between draws), plus an image checksum so builds can be compared.
// usage: drawbench [draws per frame] [frames] [mode]
//   mode 0: per draw only setVertexBytes + setFragmentBytes change (ANGLE with its state cache)
//   mode 1: per draw the SAME buffers/texture/sampler are set again as well (redundant binds)
//   mode 2: per draw the fragment texture alternates between two textures (the binding really changes)
//   mode 3: per draw a different vertex buffer offset + alternating sampler (other binding changes)
//   mode 4: mode 0 with the fragment uniforms in a struct, as ANGLE passes them (same image as mode 0)
// Test builds: DYLD_INSERT_LIBRARIES=plugshim.dylib NVMTL_TEST_PLUGIN=<NVMTLDriver> drawbench ...
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
static const char *src =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct VI { float2 p [[attribute(0)]]; float2 t [[attribute(1)]]; };\n"
    "struct VO { float4 p [[position]]; float2 t; };\n"
    "struct U { float4 xform; float4 tint; };\n"
    "vertex VO vmain(VI i [[stage_in]], constant U &u [[buffer(1)]]) {\n"
    "  VO o; o.p = float4(i.p * u.xform.zw + u.xform.xy, 0, 1); o.t = i.t; return o; }\n"
    "fragment float4 fmain(VO i [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]],\n"
    "                      constant float4 &tint [[buffer(0)]]) { return tex.sample(s, i.t) * tint; }\n"
    "struct FU { float4 tint; };\n"
    "fragment float4 fmain2(VO i [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]],\n"
    "                       constant FU &fu [[buffer(0)]]) { return tex.sample(s, i.t) * fu.tint; }\n";
static double tcpu(void) { struct timespec t; clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t); return t.tv_sec + t.tv_nsec * 1e-9; }
static double twall(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC_RAW, &t); return t.tv_sec + t.tv_nsec * 1e-9; }
static id<MTLTexture> mktex(id<MTLDevice> d, int seed) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:16 height:16 mipmapped:NO];
    id<MTLTexture> t = [d newTextureWithDescriptor:td]; uint32_t px[256];
    for (int i = 0; i < 256; i++) px[i] = 0xff000000u | (uint32_t)((i * 37 + seed * 91) & 0xff) | (uint32_t)(((i * 11 + seed * 53) & 0xff) << 8) | (uint32_t)(((i * 5 + seed * 17) & 0xff) << 16);
    [t replaceRegion:MTLRegionMake2D(0, 0, 16, 16) mipmapLevel:0 withBytes:px bytesPerRow:64]; return t;
}
int main(int argc, char **argv) { @autoreleasepool {
    const int D = argc > 1 ? atoi(argv[1]) : 2000, F = argc > 2 ? atoi(argv[2]) : 60, mode = argc > 3 ? atoi(argv[3]) : 0;
    const int W = 512;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> q = [dev newCommandQueue];
    NSError *e = nil; id<MTLLibrary> lib = [dev newLibraryWithSource:@(src) options:nil error:&e];
    if (!lib) { printf("lib: %s\nFAIL\n", e.description.UTF8String); return 1; }
    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    vd.attributes[0].format = MTLVertexFormatFloat2; vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 0;
    vd.attributes[1].format = MTLVertexFormatFloat2; vd.attributes[1].offset = 8; vd.attributes[1].bufferIndex = 0;
    vd.layouts[0].stride = 16;
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vmain"]; pd.fragmentFunction = [lib newFunctionWithName:mode == 4 ? @"fmain2" : @"fmain"];
    pd.vertexDescriptor = vd; pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    pd.colorAttachments[0].blendingEnabled = YES;
    pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha; pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne; pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!ps) { printf("pipeline: %s\nFAIL\n", e.description.UTF8String); return 1; }
    // two copies of a quad in one vertex buffer (mode 3 alternates the offset), 6 indices
    float quad[2][16] = { { 0,0, 0,0,  1,0, 1,0,  1,1, 1,1,  0,1, 0,1 }, { 0,0, 1,1,  1,0, 0,1,  1,1, 0,0,  0,1, 1,0 } };
    id<MTLBuffer> vb = [dev newBufferWithBytes:quad length:sizeof quad options:MTLResourceStorageModeShared];
    uint16_t idx[6] = { 0, 1, 2, 0, 2, 3 };
    id<MTLBuffer> ib = [dev newBufferWithBytes:idx length:sizeof idx options:MTLResourceStorageModeShared];
    id<MTLTexture> tex[2] = { mktex(dev, 1), mktex(dev, 2) };
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; id<MTLSamplerState> smp[2];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest; smp[0] = [dev newSamplerStateWithDescriptor:sd];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear; smp[1] = [dev newSamplerStateWithDescriptor:sd];
    MTLTextureDescriptor *rd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:W height:W mipmapped:NO];
    rd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; rd.storageMode = MTLStorageModeShared;
    id<MTLTexture> rt = [dev newTextureWithDescriptor:rd];
    double enc = 0, wall = 0; uint64_t sum = 0;
    for (int f = -3; f < F; f++) {                        // 3 warm-up frames
        double c0 = tcpu(), w0 = twall();
        @autoreleasepool {
            id<MTLCommandBuffer> cb = [q commandBuffer];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = rt; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.2, 0.3, 1); rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
            [re setRenderPipelineState:ps]; [re setVertexBuffer:vb offset:0 atIndex:0];
            [re setFragmentTexture:tex[0] atIndex:0]; [re setFragmentSamplerState:smp[0] atIndex:0];
            for (int i = 0; i < D; i++) {
                if (mode == 1) { [re setVertexBuffer:vb offset:0 atIndex:0]; [re setFragmentTexture:tex[0] atIndex:0]; [re setFragmentSamplerState:smp[0] atIndex:0]; }
                if (mode == 2) [re setFragmentTexture:tex[i & 1] atIndex:0];
                if (mode == 3) { [re setVertexBuffer:vb offset:(i & 1) * 64 atIndex:0]; [re setFragmentSamplerState:smp[(i >> 1) & 1] atIndex:0]; }
                unsigned h = (unsigned)(i * 2654435761u);
                float u[8] = { -1 + 2 * ((h & 1023) / 1023.f) - 0.05f, -1 + 2 * (((h >> 10) & 1023) / 1023.f) - 0.05f, 0.1f, 0.1f,
                               0, 0, 0, 0 };
                float tint[4] = { ((h >> 20) & 15) / 15.f, ((h >> 24) & 15) / 15.f, ((h >> 28) & 15) / 15.f, 0.5f };
                [re setVertexBytes:u length:sizeof u atIndex:1];
                [re setFragmentBytes:tint length:sizeof tint atIndex:0];
                [re drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt16 indexBuffer:ib indexBufferOffset:0];
            }
            [re endEncoding];
            double c1 = tcpu();
            [cb commit]; [cb waitUntilCompleted];
            if (cb.status != MTLCommandBufferStatusCompleted) { printf("command buffer status %ld\nFAIL\n", (long)cb.status); return 1; }
            if (f >= 0) { enc += c1 - c0; wall += twall() - w0; }
        }
    }
    static uint32_t px[512 * 512];
    [rt getBytes:px bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, W) mipmapLevel:0];
    sum = 1469598103934665603ull; for (int i = 0; i < W * W; i++) { sum ^= px[i]; sum *= 1099511628211ull; }
    printf("drawbench mode %d, %d draws x %d frames: encode CPU %.2f us/draw, frame wall %.2f ms, image %016llx\n",
           mode, D, F, enc / F / D * 1e6, wall / F * 1e3, (unsigned long long)sum);
    return 0;
} }
