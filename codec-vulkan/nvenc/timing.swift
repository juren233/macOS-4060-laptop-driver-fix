import Foundation
import Metal
import VideoToolbox
import CoreVideo
let dev = MTLCreateSystemDefaultDevice()!
_ = dev
let W = 1280, H = 720
let encID = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "com.nvmtl.videoencoder.avc.nvenc"
func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }
var t0 = now()
var sess: VTCompressionSession?
let spec: [String: Any] = [kVTVideoEncoderSpecification_EncoderID as String: encID]
let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
  kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
let lock = NSLock()
var sent = [Int: Double](); var results: [(Int, Double, Int, Bool)] = []
let st = VTCompressionSessionCreate(allocator: nil, width: Int32(W), height: Int32(H), codecType: kCMVideoCodecType_H264,
  encoderSpecification: spec as CFDictionary, imageBufferAttributes: attrs as CFDictionary, compressedDataAllocator: nil,
  outputCallback: { _, ref, status, _, sb in
    let idx = Int(bitPattern: ref)
    guard status == 0, let sb = sb else { print("frame \(idx) status \(status)"); return }
    var key = true
    if let a = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]], let d = a.first,
       let ns = d[kCMSampleAttachmentKey_NotSync] as? Bool { key = !ns }
    lock.lock(); results.append((idx, now() - sent[idx]!, CMSampleBufferGetTotalSampleSize(sb), key)); lock.unlock()
  }, refcon: nil, compressionSessionOut: &sess)
let tCreate = now() - t0
guard st == 0, let s = sess else { print("create failed \(st)"); exit(1) }
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: 8_000_000 as CFNumber)
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 3600 as CFNumber)
var enc: CFString? ; VTSessionCopyProperty(s, key: kVTCompressionPropertyKey_EncoderID, allocator: nil, valueOut: &enc)
t0 = now(); VTCompressionSessionPrepareToEncodeFrames(s); let tPrep = now() - t0
print("encoder \(enc ?? "?" as CFString)  create \(String(format: "%.1f", tCreate)) ms  prepare \(String(format: "%.1f", tPrep)) ms")
var pool: CVPixelBufferPool? = VTCompressionSessionGetPixelBufferPool(s)
let N = 90
let tStart = now()
for i in 0..<N {
  var pb: CVPixelBuffer?
  CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &pb)
  let b = pb!
  CVPixelBufferLockBaseAddress(b, [])
  let y = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt8.self); let ys = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
  let uv = CVPixelBufferGetBaseAddressOfPlane(b, 1)!.assumingMemoryBound(to: UInt8.self); let us = CVPixelBufferGetBytesPerRowOfPlane(b, 1)
  for r in 0..<H { for c in 0..<W { y[r*ys+c] = UInt8(truncatingIfNeeded: ((c + i*9) / 32 + r / 32) % 2 == 0 ? 60 + (c*r % 97) : 200) } }
  for r in 0..<H/2 { for c in 0..<W { uv[r*us+c] = UInt8(truncatingIfNeeded: 100 + ((c + r + i*5) % 60)) } }
  CVPixelBufferUnlockBaseAddress(b, [])
  let props: CFDictionary? = (i == 45) ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
  lock.lock(); sent[i] = now(); lock.unlock()
  VTCompressionSessionEncodeFrame(s, imageBuffer: b, presentationTimeStamp: CMTime(value: Int64(i), timescale: 40), duration: .invalid,
    frameProperties: props, sourceFrameRefcon: UnsafeMutableRawPointer(bitPattern: i), infoFlagsOut: nil)
}
VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
let total = now() - tStart
results.sort { $0.0 < $1.0 }
var bytes = 0
for r in results { bytes += r.2; if r.0 < 4 || r.3 || r.0 % 15 == 0 { print(String(format: "frame %2d  latency %6.1f ms  %7d bytes  %@", r.0, r.1, r.2, r.3 ? "KEY" : "")) } }
let lat = results.map { $0.1 }.sorted()
print(String(format: "%d frames in %.0f ms -> %.1f fps max; latency median %.1f ms p90 %.1f ms; avg %.0f kbit/frame = %.1f Mbit/s at 40fps",
  results.count, total, Double(results.count) * 1000 / total, lat[lat.count/2], lat[lat.count*9/10], Double(bytes)*8/Double(results.count)/1000, Double(bytes)*8/Double(results.count)*40/1e6))
