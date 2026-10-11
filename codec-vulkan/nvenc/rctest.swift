import Foundation
import Metal
import VideoToolbox
import CoreVideo
// usage: rctest <dylib> <kbps>   registers the dylib's NVEncH264_CreateInstance as "test.nvenc.<pid>" and measures it
let dev = MTLCreateSystemDefaultDevice()!; _ = dev
let lib = CommandLine.arguments[1], kbps = Int(CommandLine.arguments[2])!
let W = 1280, H = 720, N = 160, FPS = 40
guard let h = dlopen(lib, RTLD_NOW), let fac = dlsym(h, "NVEncH264_CreateInstance") else { print("dlopen failed"); exit(1) }
typealias RegFn = @convention(c) (UInt32, CFDictionary, UnsafeMutableRawPointer) -> Int32
let reg = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "VTRegisterVideoEncoderWithInfo")!, to: RegFn.self)
let myID = "test.nvenc.\(getpid())"
let info: NSDictionary = ["CMClassImplementationID": myID, "CMClassImplementationName": "test", "VTRating": 1, "VTIsHardwareAccelerated": true]
print("register", reg(kCMVideoCodecType_H264, info, fac))
// source frames: blocky "text" lines scrolling up 6 px per frame
var rng: UInt64 = 12345
func rnd() -> UInt64 { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return rng >> 33 }
let pageH = H * 3
var page = [UInt8](repeating: 235, count: W * pageH)
for line in stride(from: 8, to: pageH - 20, by: 22) { var x = 20; while x < W - 40 { let w = 6 + Int(rnd() % 10); if rnd() % 7 != 0 { for yy in line..<(line + 14) { for xx in x..<min(x + w, W) where rnd() % 5 != 0 { page[yy * W + xx] = 30 } } }; x += w + 3 } }
func frameY(_ i: Int) -> [UInt8] { let off = (i * 6) % (pageH - H); return Array(page[(off * W)..<((off + H) * W)]) }
var srcs = [Int: [UInt8]]()
var decoded = [Int: [UInt8]](); var sizes = [Int: (Int, Bool)]()
let lock = NSLock()
var fmt: CMFormatDescription?
var dsess: VTDecompressionSession?
var sess: VTCompressionSession?
let spec: [String: Any] = [kVTVideoEncoderSpecification_EncoderID as String: myID]
var t0 = Date()
var st = VTCompressionSessionCreate(allocator: nil, width: Int32(W), height: Int32(H), codecType: kCMVideoCodecType_H264, encoderSpecification: spec as CFDictionary,
  imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H, kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, compressedDataAllocator: nil, outputCallback: { _, ref, status, _, sb in
    let idx = Int(bitPattern: ref)
    guard status == 0, let sb = sb else { print("enc \(idx) status \(status)"); return }
    var key = true
    if let a = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]], let d = a.first, let ns = d[kCMSampleAttachmentKey_NotSync] as? Bool { key = !ns }
    lock.lock(); sizes[idx] = (CMSampleBufferGetTotalSampleSize(sb), key); lock.unlock()
    if dsess == nil {
      fmt = CMSampleBufferGetFormatDescription(sb)
      let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
      VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt!, decoderSpecification: [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: false] as CFDictionary, imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &dsess)
    }
    VTDecompressionSessionDecodeFrame(dsess!, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { ds, _, ib, _, _ in
      guard ds == 0, let ib = ib else { print("dec \(idx) status \(ds)"); return }
      CVPixelBufferLockBaseAddress(ib, .readOnly)
      let y = CVPixelBufferGetBaseAddressOfPlane(ib, 0)!.assumingMemoryBound(to: UInt8.self); let ys = CVPixelBufferGetBytesPerRowOfPlane(ib, 0)
      var out = [UInt8](repeating: 0, count: W * H); for r in 0..<H { for c in 0..<W { out[r * W + c] = y[r * ys + c] } }
      CVPixelBufferUnlockBaseAddress(ib, .readOnly)
      lock.lock(); decoded[idx] = out; lock.unlock()
    }
  }, refcon: nil, compressionSessionOut: &sess)
guard st == 0, let s = sess else { print("create failed \(st)"); exit(1) }
print(String(format: "session create %.0f ms", Date().timeIntervalSince(t0) * 1000))
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: FPS as CFNumber)
if CommandLine.arguments.count > 3 { VTSessionSetProperty(s, key: kVTCompressionPropertyKey_Quality, value: Double(CommandLine.arguments[3])! as CFNumber) }
if kbps > 0 { VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: (kbps * 1000) as CFNumber) }
let pool = VTCompressionSessionGetPixelBufferPool(s)!
for i in 0..<N {
  var pb: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb); let b = pb!
  let src = frameY(i); srcs[i] = src
  CVPixelBufferLockBaseAddress(b, [])
  let y = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt8.self); let ys = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
  let uv = CVPixelBufferGetBaseAddressOfPlane(b, 1)!.assumingMemoryBound(to: UInt8.self); let us = CVPixelBufferGetBytesPerRowOfPlane(b, 1)
  for r in 0..<H { for c in 0..<W { y[r * ys + c] = src[r * W + c] } }
  for r in 0..<H / 2 { for c in 0..<W { uv[r * us + c] = 128 } }
  CVPixelBufferUnlockBaseAddress(b, [])
  let props: CFDictionary? = (i == 100) ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
  VTCompressionSessionEncodeFrame(s, imageBuffer: b, presentationTimeStamp: CMTime(value: Int64(i), timescale: Int32(FPS)), duration: CMTime(value: 1, timescale: Int32(FPS)), frameProperties: props, sourceFrameRefcon: UnsafeMutableRawPointer(bitPattern: i), infoFlagsOut: nil)
}
VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
if let d = dsess { VTDecompressionSessionWaitForAsynchronousFrames(d) }
func psnr(_ a: [UInt8], _ b: [UInt8]) -> Double { var e = 0.0; for k in 0..<a.count { let d = Double(a[k]) - Double(b[k]); e += d * d }; e /= Double(a.count); return e == 0 ? 99 : 10 * log10(65025 / e) }
if let d = decoded[10], let src = srcs[10] { let f = FileManager.default; f.createFile(atPath: "f10.pgm", contents: Data("P5 \(W) \(H*2) 255\n".utf8) + Data(src) + Data(d)) }
var total = 0, worst = 99.0, fails = 0
for i in 0..<N {
  guard let (sz, key) = sizes[i] else { fails += 1; continue }
  total += sz
  guard let d = decoded[i] else { fails += 1; continue }
  let p = psnr(srcs[i]!, d); worst = min(worst, p)
  if true { print(String(format: "frame %3d %7d bytes %@  PSNR %.1f dB", i, sz, key ? "KEY" : "   ", p)) }
}
let secs = Double(N) / Double(FPS)
print(String(format: "target %d kbps -> actual %.0f kbps over %.1f s; second half %.0f kbps; worst PSNR %.1f dB; missing/undecoded %d",
  kbps, Double(total) * 8 / secs / 1000, secs, Double((N/2..<N).reduce(0) { $0 + (sizes[$1]?.0 ?? 0) }) * 8 / (secs / 2) / 1000, worst, fails))
