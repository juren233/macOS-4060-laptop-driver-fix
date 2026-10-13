// vtreg: does the Metal plugin register its NVDEC/NVENC codecs with VideoToolbox in this process?
// Creates the Metal device (the plugin registers at device init) and lists VideoToolbox's decoders/encoders.
// Prints one line per codec ID found and "PASS" when the H.264 hardware decoder is registered.
// usage: vtreg                         (installed plugin)
//        DYLD_INSERT_LIBRARIES=plugshim.dylib NVMTL_TEST_PLUGIN=<build> vtreg
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <VideoToolbox/VideoToolbox.h>
extern OSStatus VTCopyVideoDecoderList(CFDictionaryRef options, CFArrayRef *list);   // private, exported by VideoToolbox
int main(void) { @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) { printf("no Metal device\nFAIL\n"); return 1; }
    int dec = 0;
    CFArrayRef l = NULL;
    if (VTCopyVideoDecoderList(NULL, &l) == noErr && l) {
        for (NSDictionary *d in (__bridge NSArray *)l) {
            NSString *t = [d description];
            if ([t containsString:@"com.nvmtl."]) {
                NSRange r = [t rangeOfString:@"com.nvmtl.[a-z0-9.]+" options:NSRegularExpressionSearch];
                printf("decoder %s\n", r.location != NSNotFound ? [t substringWithRange:r].UTF8String : "com.nvmtl.?");
                dec |= [t containsString:@"com.nvmtl.videodecoder.avc.nvdec"];
            }
        }
        CFRelease(l);
    }
    l = NULL;
    if (VTCopyVideoEncoderList(NULL, &l) == noErr && l) {
        for (NSDictionary *d in (__bridge NSArray *)l) {
            NSString *i = d[(__bridge NSString *)kVTVideoEncoderList_EncoderID];
            if ([i hasPrefix:@"com.nvmtl."]) printf("encoder %s\n", i.UTF8String);
        }
        CFRelease(l);
    }
    printf("%s\n", dec ? "PASS" : "FAIL (H.264 hardware decoder not registered)");
    return dec ? 0 : 1;
} }
