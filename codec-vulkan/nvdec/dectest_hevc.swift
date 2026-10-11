import Foundation
import VideoToolbox
import CoreVideo
// usage: dectest <nvdec dylib> [W H]  — encode a colour test clip with Apple's software encoder, decode it with
// the given NVDEC dylib (registered in-process, rating 5000) and with Apple's software decoder, print PSNR per plane.
let lib = CommandLine.arguments[1]
let W = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[2])! : 1280
let H = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3])! : 720
let N = 30
guard let h = dlopen(lib, RTLD_NOW), let fac = dlsym(h, "NVDecHEVC_CreateInstance") else { print("dlopen failed \(String(cString: dlerror()))"); exit(1) }
typealias RegFn = @convention(c) (UInt32, CFDictionary, UnsafeMutableRawPointer) -> Int32
let reg = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "VTRegisterVideoDecoderWithInfo")!, to: RegFn.self)
let info: NSDictionary = ["CMClassImplementationID": "test.nvdec.\(getpid())", "VTRating": 5000, "VTIsHardwareAccelerated": true]
print("register", reg(kCMVideoCodecType_HEVC, info, fac))
struct Pic { var y: [UInt8]; var uv: [UInt8] }
func grab(_ ib: CVImageBuffer) -> Pic {
  CVPixelBufferLockBaseAddress(ib, .readOnly); defer { CVPixelBufferUnlockBaseAddress(ib, .readOnly) }
  let y = CVPixelBufferGetBaseAddressOfPlane(ib, 0)!.assumingMemoryBound(to: UInt8.self), ys = CVPixelBufferGetBytesPerRowOfPlane(ib, 0)
  let u = CVPixelBufferGetBaseAddressOfPlane(ib, 1)!.assumingMemoryBound(to: UInt8.self), us = CVPixelBufferGetBytesPerRowOfPlane(ib, 1)
  var p = Pic(y: [UInt8](repeating: 0, count: W * H), uv: [UInt8](repeating: 0, count: W * H / 2))
  for r in 0..<H { for c in 0..<W { p.y[r * W + c] = y[r * ys + c] } }
  for r in 0..<H / 2 { for c in 0..<W { p.uv[r * W + c] = u[r * us + c] } }
  return p
}
var samples = [CMSampleBuffer](); let lock = NSLock()
var sess: VTCompressionSession?
let espec: [String: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false]
var st = VTCompressionSessionCreate(allocator: nil, width: Int32(W), height: Int32(H), codecType: kCMVideoCodecType_HEVC, encoderSpecification: espec as CFDictionary,
  imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H] as CFDictionary,
  compressedDataAllocator: nil, outputCallback: { _, _, s, _, sb in if s == 0, let sb = sb { lock.lock(); samples.append(sb); lock.unlock() } }, refcon: nil, compressionSessionOut: &sess)
guard st == 0, let s = sess else { print("enc create \(st)"); exit(1) }
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_Quality, value: 0.9 as CFNumber)
let pool = VTCompressionSessionGetPixelBufferPool(s)!
for i in 0..<N {
  var pb: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb); let b = pb!
  CVPixelBufferLockBaseAddress(b, [])
  let y = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt8.self), ys = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
  let uv = CVPixelBufferGetBaseAddressOfPlane(b, 1)!.assumingMemoryBound(to: UInt8.self), us = CVPixelBufferGetBytesPerRowOfPlane(b, 1)
  for r in 0..<H { for c in 0..<W { let sq = ((c + i * 4) / 40 + r / 40) & 1; y[r * ys + c] = UInt8(16 + (c * 200 / W + r * 19 / H + sq * 30) % 220) } }
  for r in 0..<H / 2 { for c in stride(from: 0, to: W, by: 2) { uv[r * us + c] = UInt8(40 + c * 170 / W); uv[r * us + c + 1] = UInt8(40 + (r + i) * 340 / H % 170) } }
  CVPixelBufferUnlockBaseAddress(b, [])
  VTCompressionSessionEncodeFrame(s, imageBuffer: b, presentationTimeStamp: CMTime(value: Int64(i), timescale: 30), duration: CMTime(value: 1, timescale: 30), frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil)
}
VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
print("encoded \(samples.count) samples")
func decode(_ hw: Bool) -> ([Pic], Bool) {
  var d: VTDecompressionSession?
  let spec: [String: Any] = hw ? [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String: true] : [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: false]
  let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
  let r = VTDecompressionSessionCreate(allocator: nil, formatDescription: CMSampleBufferGetFormatDescription(samples[0])!, decoderSpecification: spec as CFDictionary, imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &d)
  guard r == 0, let ds = d else { print("dec create (hw=\(hw)) \(r)"); exit(1) }
  var usingHW: CFTypeRef?; VTSessionCopyProperty(ds, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: nil, valueOut: &usingHW)
  var out = [Pic]()
  for sb in samples { VTDecompressionSessionDecodeFrame(ds, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { st, _, ib, _, _ in if st == 0, let ib = ib { out.append(grab(ib)) } else { print("dec status \(st)") } }; VTDecompressionSessionWaitForAsynchronousFrames(ds) }
  VTDecompressionSessionFinishDelayedFrames(ds); VTDecompressionSessionWaitForAsynchronousFrames(ds); VTDecompressionSessionInvalidate(ds)
  return (out, (usingHW as? Bool) ?? false)
}
let (ref, _) = decode(false), (hw, isHW) = decode(true)
print("sw \(ref.count) frames, nvdec \(hw.count) frames, UsingHardwareDecoder=\(isHW)")
func psnr(_ a: [UInt8], _ b: [UInt8]) -> Double { var e = 0.0; for k in 0..<a.count { let d = Double(a[k]) - Double(b[k]); e += d * d }; e /= Double(a.count); return e == 0 ? 99 : 10 * log10(65025 / e) }
var wy = 99.0, wc = 99.0
for i in 0..<min(ref.count, hw.count) { wy = min(wy, psnr(ref[i].y, hw[i].y)); wc = min(wc, psnr(ref[i].uv, hw[i].uv)) }
print(String(format: "RESULT %dx%d worst luma %.1f dB, worst chroma %.1f dB (99 = bit-exact)", W, H, wy, wc))
if let a = ref.first, let b = hw.first { FileManager.default.createFile(atPath: "cmp.pgm", contents: Data("P5 \(W) \(H*2) 255\n".utf8) + Data(a.y) + Data(b.y)) }
