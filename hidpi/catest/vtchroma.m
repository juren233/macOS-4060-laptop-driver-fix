// vtchroma: make a short clip (H.264 or HEVC) with strongly coloured content, then decode it through VideoToolbox over and
// over (new session each time, like a hover preview) and check that every decoded NV12 frame has a non-zero chroma plane.
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreVideo/CoreVideo.h>
static int W = 640, H = 360, NF = 48;
static void makeClip(NSString *path, AVVideoCodecType codec) {
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    AVAssetWriter *w = [AVAssetWriter assetWriterWithURL:[NSURL fileURLWithPath:path] fileType:AVFileTypeMPEG4 error:nil];
    AVAssetWriterInput *in = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{ AVVideoCodecKey: codec, AVVideoWidthKey: @(W), AVVideoHeightKey: @(H), AVVideoCompressionPropertiesKey: @{ AVVideoMaxKeyFrameIntervalKey: @24, AVVideoAverageBitRateKey: @2000000 } }];
    AVAssetWriterInputPixelBufferAdaptor *ad = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:in sourcePixelBufferAttributes:@{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA), (id)kCVPixelBufferWidthKey: @(W), (id)kCVPixelBufferHeightKey: @(H) }];
    [w addInput:in]; [w startWriting]; [w startSessionAtSourceTime:kCMTimeZero];
    for (int f = 0; f < NF; f++) { while (!in.readyForMoreMediaData) usleep(1000); CVPixelBufferRef pb = NULL; CVPixelBufferPoolCreatePixelBuffer(NULL, ad.pixelBufferPool, &pb);
        CVPixelBufferLockBaseAddress(pb, 0); uint8_t *p = CVPixelBufferGetBaseAddress(pb); size_t r = CVPixelBufferGetBytesPerRow(pb);
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) { uint8_t *px = p + y * r + x * 4; int bar = (x > (f * 13) % W && x < (f * 13) % W + 40);
            px[0] = bar ? 255 : (x < W / 2 ? 220 : 40); px[1] = bar ? 255 : 60; px[2] = bar ? 255 : (x < W / 2 ? 40 : 230); px[3] = 255; }
        CVPixelBufferUnlockBaseAddress(pb, 0); [ad appendPixelBuffer:pb withPresentationTime:CMTimeMake(f, 24)]; CVPixelBufferRelease(pb); }
    [in markAsFinished]; dispatch_semaphore_t s = dispatch_semaphore_create(0); [w finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(s); }]; dispatch_semaphore_wait(s, DISPATCH_TIME_FOREVER);
}
static int sessionsRun, framesTot, framesBad, framesBadFirst;
static void decodeOnce(NSString *path, int sess, int verbose) {
    AVAsset *a = [AVAsset assetWithURL:[NSURL fileURLWithPath:path]]; AVAssetTrack *t = [[a tracksWithMediaType:AVMediaTypeVideo] firstObject];
    AVAssetReader *rd = [AVAssetReader assetReaderWithAsset:a error:nil]; AVAssetReaderTrackOutput *o = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:t outputSettings:nil]; [rd addOutput:o]; [rd startReading];
    CMFormatDescriptionRef fd = (__bridge CMFormatDescriptionRef)t.formatDescriptions.firstObject; VTDecompressionSessionRef vs = NULL;
    NSDictionary *spec = @{ (id)kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: @YES };
    NSDictionary *dst = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange), (id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferMetalCompatibilityKey: @YES };
    __block int fr = 0, bad = 0, badFirst = 0;
    VTDecompressionOutputCallbackRecord cbr = { 0 };
    VTDecompressionOutputHandler h = ^(OSStatus st, VTDecodeInfoFlags fl, CVImageBufferRef img, CMTime pts, CMTime dur) { if (st || !img) return; fr++;
        CVPixelBufferLockBaseAddress(img, kCVPixelBufferLock_ReadOnly); uint8_t *cp = CVPixelBufferGetBaseAddressOfPlane(img, 1); size_t cr = CVPixelBufferGetBytesPerRowOfPlane(img, 1); size_t ch = CVPixelBufferGetHeightOfPlane(img, 1), cw = CVPixelBufferGetWidthOfPlane(img, 1);
        long nz = 0, tot = 0; for (size_t y = 0; y < ch; y += 4) for (size_t x = 0; x < cw * 2; x += 2) { tot++; if (cp[y * cr + x] || cp[y * cr + x + 1]) nz++; }
        CVPixelBufferUnlockBaseAddress(img, kCVPixelBufferLock_ReadOnly); if (nz * 10 < tot) { bad++; if (fr <= 3) badFirst++; if (verbose && bad <= 3) printf("   session %d frame %d: chroma plane %ld/%ld non-zero (green frame)\n", sess, fr, nz, tot); } };
    OSStatus rc = VTDecompressionSessionCreate(NULL, fd, (__bridge CFDictionaryRef)spec, (__bridge CFDictionaryRef)dst, NULL, &vs); if (rc) { printf("VTDecompressionSessionCreate failed %d\n", (int)rc); return; }
    if (sess == 0) { CFBooleanRef hw = NULL; VTSessionCopyProperty(vs, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, NULL, (void *)&hw); CFStringRef dn = NULL; VTSessionCopyProperty(vs, CFSTR("DecoderID"), NULL, (void *)&dn); printf("  hardware decoder in use: %s\n", hw && CFBooleanGetValue(hw) ? "yes" : "NO (software)"); }
    CMSampleBufferRef sb; while ((sb = [o copyNextSampleBuffer])) { VTDecompressionSessionDecodeFrameWithOutputHandler(vs, sb, kVTDecodeFrame_EnableAsynchronousDecompression, NULL, h); CFRelease(sb); }
    VTDecompressionSessionWaitForAsynchronousFrames(vs); VTDecompressionSessionInvalidate(vs); CFRelease(vs);
    sessionsRun++; framesTot += fr; framesBad += bad; framesBadFirst += badFirst;
}
int main(int argc, char **argv) { @autoreleasepool {
    const char *which = argc > 1 ? argv[1] : "h264"; int sessions = argc > 2 ? atoi(argv[2]) : 30; AVVideoCodecType codec = !strcmp(which, "hevc") ? AVVideoCodecTypeHEVC : AVVideoCodecTypeH264;
    NSString *path = [NSString stringWithFormat:@"%@/vtchroma-%s.mp4", NSTemporaryDirectory(), which]; makeClip(path, codec); printf("%s clip %dx%d, %d frames; %d sessions\n", which, W, H, NF, sessions);
    for (int s = 0; s < sessions; s++) decodeOnce(path, s, 1);
    printf("%s: %d sessions, %d frames decoded, %d frames with empty chroma (%d of them among the first 3 frames of a session)  %s\n", which, sessionsRun, framesTot, framesBad, framesBadFirst, framesBad ? "FAIL" : "PASS"); return framesBad != 0; } }
