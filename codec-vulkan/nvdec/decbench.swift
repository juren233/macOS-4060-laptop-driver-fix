import Foundation
import VideoToolbox
import CoreVideo
// usage: decbench <nvdec dylib> <h264|hevc> [W H frames loops]
// Encodes a moving test clip with Apple's software encoder (cached in /tmp/decbench-<codec>-WxH-N.bin), then decodes
// it `loops` times through the given NVDEC dylib (registered in-process, rating 5000), one frame at a time, synchronously.
// Prints CPU (whole process, all threads) and wall time per decoded frame, and a checksum of every decoded picture
// (so a patched build can be compared with the original for bit-exactness).
let a = CommandLine.arguments
let lib = a[1], hevc = a[2] == "hevc"
let W = a.count > 4 ? Int(a[3])! : 3840, H = a.count > 4 ? Int(a[4])! : 2160
let N = a.count > 5 ? Int(a[5])! : 30, loops = a.count > 6 ? Int(a[6])! : 4
let codec = hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
guard let h = dlopen(lib, RTLD_NOW), let fac = dlsym(h, hevc ? "NVDecHEVC_CreateInstance" : "NVDecH264_CreateInstance") else { print("dlopen failed"); exit(1) }
typealias RegFn = @convention(c) (UInt32, CFDictionary, UnsafeMutableRawPointer) -> Int32
let reg = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "VTRegisterVideoDecoderWithInfo")!, to: RegFn.self)
let info: NSDictionary = ["CMClassImplementationID": "test.nvdec.\(getpid())", "VTRating": 5000, "VTIsHardwareAccelerated": true]
_ = reg(codec, info, fac)
func cpu() -> Double { var u = rusage(); getrusage(RUSAGE_SELF, &u)
  return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6 }
// ---- encode (or load) the clip: [UInt32 len][bytes] per frame + parameter sets in front
let cache = "/tmp/decbench-\(a[2])-\(W)x\(H)-\(N).bin"
var frames = [Data](); var psets = [Data]()
var sbs = [CMSampleBuffer](); let lock = NSLock()
if let d = FileManager.default.contents(atPath: cache) {
  var o = 0; func rd() -> Data { let n = d.subdata(in: o..<o + 4).withUnsafeBytes { Int($0.load(as: UInt32.self)) }; o += 4; let r = d.subdata(in: o..<o + n); o += n; return r }
  let np = Int(d.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self) }); o = 4
  for _ in 0..<np { psets.append(rd()) }; while o < d.count { frames.append(rd()) }
} else {
  var sess: VTCompressionSession?
  let espec: [String: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false]
  VTCompressionSessionCreate(allocator: nil, width: Int32(W), height: Int32(H), codecType: codec, encoderSpecification: espec as CFDictionary,
    imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: { _, _, s, _, sb in if s == 0, let sb = sb { lock.lock(); sbs.append(sb); lock.unlock() } },
    refcon: nil, compressionSessionOut: &sess)
  VTSessionSetProperty(sess!, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
  VTSessionSetProperty(sess!, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: 40_000_000))
  VTSessionSetProperty(sess!, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: 1000))
  for k in 0..<N {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, W, H, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    let y = CVPixelBufferGetBaseAddressOfPlane(pb!, 0)!.assumingMemoryBound(to: UInt8.self), ys = CVPixelBufferGetBytesPerRowOfPlane(pb!, 0)
    let c = CVPixelBufferGetBaseAddressOfPlane(pb!, 1)!.assumingMemoryBound(to: UInt8.self), cs = CVPixelBufferGetBytesPerRowOfPlane(pb!, 1)
    var r: UInt32 = UInt32(k) &* 2654435761
    for row in 0..<H { for col in 0..<W { r = r &* 1103515245 &+ 12345
      y[row * ys + col] = UInt8(truncatingIfNeeded: ((col + k * 8) ^ (row + k * 3)) &+ Int(r >> 28)) } }
    for row in 0..<H / 2 { for col in 0..<W { c[row * cs + col] = UInt8(truncatingIfNeeded: (col / 2 + row + k * 5)) } }
    CVPixelBufferUnlockBaseAddress(pb!, [])
    VTCompressionSessionEncodeFrame(sess!, imageBuffer: pb!, presentationTimeStamp: CMTime(value: Int64(k), timescale: 30), duration: .invalid, frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil)
  }
  VTCompressionSessionCompleteFrames(sess!, untilPresentationTimeStamp: .invalid)
  let fd = CMSampleBufferGetFormatDescription(sbs[0])!
  var cnt = 0
  if hevc { CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &cnt, nalUnitHeaderLengthOut: nil) }
  else { CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &cnt, nalUnitHeaderLengthOut: nil) }
  for i in 0..<cnt { var p: UnsafePointer<UInt8>?; var n = 0
    if hevc { CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &p, parameterSetSizeOut: &n, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) }
    else { CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &p, parameterSetSizeOut: &n, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) }
    psets.append(Data(bytes: p!, count: n)) }
  for sb in sbs { let bb = CMSampleBufferGetDataBuffer(sb)!; var d = Data(count: CMBlockBufferGetDataLength(bb))
    d.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }; frames.append(d) }
  var out = Data(); func wr(_ d: Data) { var n = UInt32(d.count); out.append(Data(bytes: &n, count: 4)); out.append(d) }
  var np = UInt32(psets.count); out.append(Data(bytes: &np, count: 4)); psets.forEach(wr); frames.forEach(wr)
  FileManager.default.createFile(atPath: cache, contents: out)
}
// ---- decode
var fd: CMFormatDescription?
let ptrs = psets.map { d -> UnsafeMutablePointer<UInt8> in let p = UnsafeMutablePointer<UInt8>.allocate(capacity: d.count); d.copyBytes(to: p, count: d.count); return p }
let sizes = psets.map { $0.count }
let pp = ptrs.map { UnsafePointer($0) }
if hevc { CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: pp.count, parameterSetPointers: pp, parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fd) }
else { CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: pp.count, parameterSetPointers: pp, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fd) }
var ds: VTDecompressionSession?
let dspec: [String: Any] = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String: true]
let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
let st = VTDecompressionSessionCreate(allocator: nil, formatDescription: fd!, decoderSpecification: dspec as CFDictionary, imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &ds)
if st != 0 { print("decoder session \(st)"); exit(1) }
var hw: CFBoolean?; VTSessionCopyProperty(ds!, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: nil, valueOut: &hw)
var sums = [UInt64](); var bad = 0
func decode(_ d: Data, _ k: Int, _ keep: Bool) {
  var bb: CMBlockBuffer?; let n = d.count
  CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: n, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: n, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &bb)
  d.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb!, offsetIntoDestination: 0, dataLength: n) }
  var sb: CMSampleBuffer?; var sz = n; var t = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: Int64(k), timescale: 30), decodeTimeStamp: .invalid)
  CMSampleBufferCreateReady(allocator: nil, dataBuffer: bb, formatDescription: fd, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &t, sampleSizeEntryCount: 1, sampleSizeArray: &sz, sampleBufferOut: &sb)
  let s = VTDecompressionSessionDecodeFrame(ds!, sampleBuffer: sb!, flags: [], infoFlagsOut: nil) { st, _, ib, _, _ in
    guard st == 0, let ib = ib else { bad += 1; return }
    if !keep { return }
    CVPixelBufferLockBaseAddress(ib, .readOnly)
    var hsh: UInt64 = 1469598103934665603
    for p in 0..<2 { let b = CVPixelBufferGetBaseAddressOfPlane(ib, p)!.assumingMemoryBound(to: UInt64.self), rs = CVPixelBufferGetBytesPerRowOfPlane(ib, p) / 8
      let hh = p == 0 ? H : H / 2; for r in stride(from: 0, to: hh, by: 7) { for c in stride(from: 0, to: W / 8, by: 3) { hsh = (hsh ^ b[r * rs + c]) &* 1099511628211 } } }
    CVPixelBufferUnlockBaseAddress(ib, .readOnly); sums.append(hsh) }
  if s != 0 { bad += 1 }
}
for (k, f) in frames.enumerated() { decode(f, k, true) }   // warm-up + checksums
let c0 = cpu(), t0 = Date()
for l in 0..<loops { for (k, f) in frames.enumerated() { decode(f, l * frames.count + k + frames.count, false) } }
let M = Double(loops * frames.count), cc = (cpu() - c0) * 1000 / M, ww = Date().timeIntervalSince(t0) * 1000 / M
var all: UInt64 = 0; for s in sums { all = (all &* 31) &+ s }
print(String(format: "%@ %dx%d hw=%@ %d frames x %d: CPU %.2f ms/frame, wall %.2f ms/frame, errors %d, checksum %016llx",
  a[2], W, H, (hw == kCFBooleanTrue) ? "yes" : "no", frames.count, loops, cc, ww, bad, all))
