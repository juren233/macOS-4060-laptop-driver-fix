// tiledmipsown: tiledmips + an app that writes mip level 1 itself: the copied tiled texture's re-sync after a buffer rewrite
// must rebuild only what the app did not write (upstream 2.3.6 #274's _mipsWritten idea on our GPU mip path). Then level 1 keeps
// the app's bytes while level 0 follows the buffer.
// tiledmips: Core Animation makes trilinear layer contents (Dock badge numbers: 108 px image, minificationFilterBias -0.5) with
// newTiledTextureWithBytesNoCopy and a MIPMAPPED descriptor; the buffer holds level 0 only and the driver must build the chain.
// Levels 1+ were left empty (badge numbers vanished below magnified size). Checks every level after creation and after the
// buffer is rewritten (the copy-in re-upload path). Prints PASS/FAIL.
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <mach/mach.h>
@interface NSObject (T) - (id)newTiledTextureWithBytesNoCopy:(void *)b length:(NSUInteger)l deallocator:(id)d descriptor:(MTLTextureDescriptor *)desc offset:(NSUInteger)o bytesPerRow:(NSUInteger)bpr; @end
static id<MTLDevice> dev; static id<MTLCommandQueue> q;
static int bad;
static void levelstats(id<MTLTexture> t, const char *tag, double want) {
  printf("%s:", tag);
  for (NSUInteger l = 0; l < t.mipmapLevelCount; l++) { NSUInteger w = MAX(1, t.width >> l), h = MAX(1, t.height >> l);
    id<MTLBuffer> b = [dev newBufferWithLength:w*h*4 options:0]; id<MTLCommandBuffer> cb=[q commandBuffer]; id<MTLBlitCommandEncoder> e=[cb blitCommandEncoder];
    [e copyFromTexture:t sourceSlice:0 sourceLevel:l sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(w,h,1) toBuffer:b destinationOffset:0 destinationBytesPerRow:w*4 destinationBytesPerImage:w*h*4];
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
    const uint8_t *p = b.contents; double a = 0; for (NSUInteger i = 0; i < w*h; i++) a += p[i*4+3]; a /= (w*h); printf(" L%lu=%.1f", l, a); if (l < t.mipmapLevelCount - 1 && (a < want * 0.7 || a > want * 1.3)) bad++; }
  printf("  (mean alpha per level, want ~%.1f)\n", want); }
// binds the texture in a draw so the plugin's surface-in/copy-in runs (as Core Animation's draws do)
static void touch(id<MTLTexture> t) {
  MTLTextureDescriptor *od=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:8 height:8 mipmapped:NO]; od.usage=MTLTextureUsageRenderTarget; od.storageMode=MTLStorageModePrivate;
  static id<MTLRenderPipelineState> ps; NSError *err;
  if (!ps) { id<MTLLibrary> lib=[dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nstruct V{float4 p[[position]];};\nvertex V vs(uint i[[vertex_id]]){V o; float2 u=float2((i<<1)&2,i&2); o.p=float4(u*2-1,0,1); return o;}\nfragment float4 fs(V i[[stage_in]], texture2d<float> t[[texture(0)]]){ return t.read(uint2(0,0)); }\n" options:nil error:&err];
    MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new]; pd.vertexFunction=[lib newFunctionWithName:@"vs"]; pd.fragmentFunction=[lib newFunctionWithName:@"fs"]; pd.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm; ps=[dev newRenderPipelineStateWithDescriptor:pd error:&err]; }
  MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor]; rp.colorAttachments[0].texture=[dev newTextureWithDescriptor:od]; rp.colorAttachments[0].loadAction=MTLLoadActionClear;
  id<MTLCommandBuffer> cb=[q commandBuffer]; id<MTLRenderCommandEncoder> re=[cb renderCommandEncoderWithDescriptor:rp]; [re setRenderPipelineState:ps]; [re setFragmentTexture:t atIndex:0]; [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [re endEncoding]; [cb commit]; [cb waitUntilCompleted]; }
int main(){ @autoreleasepool {
  dev = MTLCreateSystemDefaultDevice(); q = [dev newCommandQueue];
  const NSUInteger W = 108, BPR = 448, LEN = (BPR*W + 4095) & ~4095ul;
  vm_address_t a = 0; vm_allocate(mach_task_self(), &a, LEN, VM_FLAGS_ANYWHERE); uint8_t *bytes = (uint8_t *)a;
  for (NSUInteger y = 0; y < W; y++) for (NSUInteger x = 0; x < W; x++) { uint8_t *p = bytes + y*BPR + x*4; uint8_t v = (x >= 40 && x < 60) ? 200 : 0; p[0]=p[1]=p[2]=v/2; p[3]=v; }
  MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:W mipmapped:YES];
  d.usage = MTLTextureUsageShaderRead; d.storageMode = MTLStorageModeShared;
  id<MTLTexture> t = [(id)dev newTiledTextureWithBytesNoCopy:bytes length:LEN deallocator:nil descriptor:d offset:0 bytesPerRow:BPR];
  if (!t) { printf("newTiledTextureWithBytesNoCopy -> nil\n"); return 1; }
  printf("tiled texture %lux%lu, %lu levels\n", t.width, t.height, t.mipmapLevelCount);
  levelstats(t, "after create        ", 200.0*20/108);
  // Core Animation refills recycled buffers after making the texture: the re-upload path must regenerate the chain too
  for (NSUInteger y = 0; y < W; y++) for (NSUInteger x = 0; x < W; x++) { uint8_t *p = bytes + y*BPR + x*4; p[0]=p[1]=p[2]=p[3] = (x < W/2) ? 255 : 0; }
  touch(t);
  levelstats(t, "after buffer rewrite", 127.5);
  // the app writes level 1 itself (alpha 37 everywhere), then the buffer changes again (alpha 255 everywhere)
  { NSUInteger w1 = MAX(1, W >> 1); uint8_t *l1 = calloc(w1 * w1, 4); for (NSUInteger i = 0; i < w1 * w1; i++) l1[i*4+3] = 37;
    [t replaceRegion:MTLRegionMake2D(0, 0, w1, w1) mipmapLevel:1 withBytes:l1 bytesPerRow:w1 * 4]; free(l1); }
  for (NSUInteger y = 0; y < W; y++) for (NSUInteger x = 0; x < W; x++) { uint8_t *p = bytes + y*BPR + x*4; p[0]=p[1]=p[2]=p[3] = 255; }
  touch(t);
  { int was = bad; bad = 0; printf("after app wrote level 1 + buffer rewrite:");
    for (NSUInteger l = 0; l < 2; l++) { NSUInteger w = MAX(1, t.width >> l), h = MAX(1, t.height >> l);
      id<MTLBuffer> b = [dev newBufferWithLength:w*h*4 options:0]; id<MTLCommandBuffer> cb=[q commandBuffer]; id<MTLBlitCommandEncoder> e=[cb blitCommandEncoder];
      [e copyFromTexture:t sourceSlice:0 sourceLevel:l sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(w,h,1) toBuffer:b destinationOffset:0 destinationBytesPerRow:w*4 destinationBytesPerImage:w*h*4];
      [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
      const uint8_t *p = b.contents; double a = 0; for (NSUInteger i = 0; i < w*h; i++) a += p[i*4+3]; a /= (w*h);
      const double want = l ? 37 : 255; printf(" L%lu=%.1f (want %.0f)", l, a, want); if (a < want - 1 || a > want + 1) bad++; }
    printf("\n"); bad += was; }
  printf("%s\n", bad ? "FAIL" : "PASS");
  return bad ? 1 : 0;
}}
