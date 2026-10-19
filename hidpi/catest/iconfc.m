// iconfc: Apple's icon shaders (RenderBox + IconRendering) through newFunctionWithName:constantValues: on the default device.
// Every function that declares function constants is specialized twice (all constants zero / false, then all one / true);
// a specialization must either produce a function or defer it to pipeline creation (a function the plugin returns without
// SPIR-V). It must never come back nil: RenderBox treats that as a precondition failure and draws the icon glyph black
// (translator 3cf58ff8, 2026-10-18: "visible function \"custom_fn\" is called on a live path but no linked function supplies
// it" was not one of the refusals the plugin defers, so the specialized function was nil).
// Prints one line per failure and a summary; the last line is PASS or FAIL.
// Build: clang -fobjc-arc -framework Foundation -framework Metal iconfc.m -o iconfc
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static NSArray<NSString *> *kLibs(void) {
    return @[@"/System/Library/PrivateFrameworks/RenderBox.framework/Versions/A/Resources/default.metallib",
             @"/System/Library/PrivateFrameworks/IconRendering.framework/Versions/A/Resources/default.metallib"];
}

static void setAll(MTLFunctionConstantValues *cv, NSDictionary<NSString *, MTLFunctionConstant *> *fcs, int v) {
    for (MTLFunctionConstant *c in fcs.allValues) {
        uint8_t b[64] = {0};
        if (v) {
            switch (c.type) {
                case MTLDataTypeBool: case MTLDataTypeChar: case MTLDataTypeUChar: b[0] = 1; break;
                case MTLDataTypeShort: case MTLDataTypeUShort: *(uint16_t *)b = 1; break;
                case MTLDataTypeInt: case MTLDataTypeUInt: *(uint32_t *)b = 1; break;
                case MTLDataTypeFloat: *(float *)b = 1.0f; break;
                case MTLDataTypeHalf: *(uint16_t *)b = 0x3c00; break;
                default: b[0] = 1; break;
            }
        }
        [cv setConstantValue:b type:c.type atIndex:c.index];
    }
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { printf("no device\nFAIL\n"); return 1; }
        unsigned fns = 0, spec = 0, ok = 0, deferred = 0, bad = 0, libs = 0;
        for (NSString *path in kLibs()) {
            NSError *e = nil;
            id<MTLLibrary> lib = [dev newLibraryWithURL:[NSURL fileURLWithPath:path] error:&e];
            if (!lib) { printf("library %s: %s\n", path.lastPathComponent.UTF8String, e.localizedDescription.UTF8String ?: "nil"); bad++; continue; }
            libs++;
            for (NSString *name in lib.functionNames) {
                id<MTLFunction> plain = [lib newFunctionWithName:name];
                NSDictionary *fcs = plain.functionConstantsDictionary;
                fns++;
                if (!fcs.count) continue;
                for (int v = 0; v < 2; v++) {
                    MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new];
                    setAll(cv, fcs, v);
                    NSError *fe = nil;
                    id<MTLFunction> f = [lib newFunctionWithName:name constantValues:cv error:&fe];
                    spec++;
                    if (!f) {
                        bad++;
                        printf("NIL %s %s (constants=%d, %lu of them): %s\n", path.pathComponents[path.pathComponents.count - 5].UTF8String,
                               name.UTF8String, v, (unsigned long)fcs.count, fe.localizedDescription.UTF8String ?: "no error");
                        continue;
                    }
                    // a deferred function carries no SPIR-V yet; the plugin exposes that through its ivar only, so count by class
                    BOOL def = NO;
                    @try { def = [[(NSObject *)f valueForKey:@"_needsLink"] boolValue]; } @catch (NSException *x) { def = NO; }
                    if (def) deferred++; else ok++;
                }
            }
        }
        printf("iconfc: %u libraries, %u functions, %u specializations: %u specialized, %u deferred to pipeline creation, %u nil\n",
               libs, fns, spec, ok, deferred, bad);
        // The deferred functions are only half the contract: at pipeline creation the pipeline's linked functions supply
        // custom_fn (RenderBox links its glass functions under that name). Link a stand-in custom_fn with the signature the
        // reference declares (float2, half4, constant float *, device const uchar *, three texture2d<half>) into each custom
        // fragment and build the pipeline with its own vertex function.
        unsigned pipes = 0, pipesOk = 0;
        NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "[[visible]] half4 custom_fn(float2 p, half4 c, constant float *args, device const uchar *data,"
            " texture2d<half> t0, texture2d<half> t1, texture2d<half> t2) { return half4(half(p.x), c.y, half(args[0]), 1.0h); }\n";
        NSError *se = nil;
        MTLCompileOptions *co = [MTLCompileOptions new];
        id<MTLLibrary> cust = [dev newLibraryWithSource:src options:co error:&se];
        id<MTLFunction> cfn = [cust newFunctionWithName:@"custom_fn"];
        id<MTLLibrary> rb = [dev newLibraryWithURL:[NSURL fileURLWithPath:kLibs()[0]] error:nil];
        if (!cfn) { printf("custom_fn stand-in did not compile: %s\n", se.localizedDescription.UTF8String ?: "nil"); bad++; }
        for (NSString *pair in @[@"custom_effect", @"filter_custom", @"primitive_custom", @"accumulator_custom"]) {
            if (!cfn || !rb) break;
            id<MTLFunction> vf = [rb newFunctionWithName:[pair stringByAppendingString:@"_vertex"]];
            NSString *fname = [pair stringByAppendingString:@"_fragment"];
            id<MTLFunction> plain = [rb newFunctionWithName:fname];
            for (int v = 0; v < 2; v++) {
                MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new];
                setAll(cv, plain.functionConstantsDictionary, v);
                id<MTLFunction> ff = [rb newFunctionWithName:fname constantValues:cv error:nil];
                MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
                d.vertexFunction = vf; d.fragmentFunction = ff;
                d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
                d.colorAttachments[1].pixelFormat = MTLPixelFormatRG16Float;
                MTLLinkedFunctions *lf = [MTLLinkedFunctions linkedFunctions]; lf.functions = @[cfn];
                d.fragmentLinkedFunctions = lf;
                NSError *pe = nil; pipes++;
                id<MTLRenderPipelineState> ps = (vf && ff) ? [dev newRenderPipelineStateWithDescriptor:d error:&pe] : nil;
                if (ps) pipesOk++;
                else { bad++; printf("PIPELINE %s (constants=%d): %s\n", fname.UTF8String, v, pe.localizedDescription.UTF8String ?: (vf && ff ? "nil" : "no function")); }
            }
        }
        printf("iconfc: custom fragments with a linked custom_fn: %u of %u pipelines built\n", pipesOk, pipes);
        printf("%s\n", (bad == 0 && libs == 2 && spec > 0 && pipes == 8) ? "PASS" : "FAIL");
        return bad ? 1 : 0;
    }
}
