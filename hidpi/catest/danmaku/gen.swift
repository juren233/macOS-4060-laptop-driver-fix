import Foundation
import AVFoundation
import CoreVideo
import VideoToolbox
// gen OUT W H FPS SECONDS KBPS: moving gradient + bars, H.264 High in MP4 (+faststart)
let a = CommandLine.arguments; let out = URL(fileURLWithPath: a[1]); let W = Int(a[2])!, H = Int(a[3])!, F = Int(a[4])!, N = Int(a[5])! * F, K = Int(a[6])!
try? FileManager.default.removeItem(at: out)
let w = try! AVAssetWriter(outputURL: out, fileType: .mp4); w.shouldOptimizeForNetworkUse = true
let hevc = ProcessInfo.processInfo.environment["HEVC"] != nil   // HEVC=1: HEVC Main in an hvc1 track
var cp: [String: Any] = [AVVideoAverageBitRateKey: K * 1000, AVVideoMaxKeyFrameIntervalKey: F * 2, AVVideoAllowFrameReorderingKey: false]
cp[AVVideoProfileLevelKey] = hevc ? (kVTProfileLevel_HEVC_Main_AutoLevel as String) : AVVideoProfileLevelH264HighAutoLevel
let vi = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
  AVVideoCompressionPropertiesKey: cp])
let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vi, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H])
w.add(vi); w.startWriting(); w.startSession(atSourceTime: .zero)
for i in 0..<N {
  while !vi.isReadyForMoreMediaData { usleep(1000) }
  var pb: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, ad.pixelBufferPool!, &pb); let b = pb!
  CVPixelBufferLockBaseAddress(b, [])
  let y = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt8.self), ys = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
  let uv = CVPixelBufferGetBaseAddressOfPlane(b, 1)!.assumingMemoryBound(to: UInt8.self), us = CVPixelBufferGetBytesPerRowOfPlane(b, 1)
  for r in 0..<H { let row = y + r * ys; for c in 0..<W { row[c] = UInt8(truncatingIfNeeded: 30 + ((c + i * 12) % 400) / 3 + ((r / 60 + (c + i * 6) / 60) & 1) * 40) } }
  for r in 0..<H / 2 { let row = uv + r * us; for c in stride(from: 0, to: W, by: 2) { row[c] = UInt8(truncatingIfNeeded: 90 + (c + i * 4) % 80); row[c + 1] = UInt8(truncatingIfNeeded: 100 + (r + i * 3) % 70) } }
  CVPixelBufferUnlockBaseAddress(b, [])
  ad.append(b, withPresentationTime: CMTime(value: Int64(i), timescale: Int32(F)))
}
vi.markAsFinished(); let sem = DispatchSemaphore(value: 0); w.finishWriting { sem.signal() }; sem.wait()
print(w.status == .completed ? "wrote \(out.path)" : "FAILED \(String(describing: w.error))")
