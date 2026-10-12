import Foundation
import Metal
let dev = MTLCreateSystemDefaultDevice()!
let lib = try! dev.makeLibrary(URL: URL(fileURLWithPath: "sitest.metallib"))
let N = 37
func h2f(_ h: UInt16) -> Float { let s: Float = (h & 0x8000) != 0 ? -1 : 1; let e = Int((h >> 10) & 31), m = Float(h & 1023)
  if e == 0 { return s * m / 1024 * pow(2, -14) }; return s * (1 + m / 1024) * pow(2, Float(e - 15)) }
let halves: [UInt16] = [0x3C00,0xBC00,0x3800,0x4900,0xC200,0x0000,0x4200,0x3555]
var rng: UInt32 = 12345
func rnd() -> UInt32 { rng = rng &* 1664525 &+ 1013904223; return rng >> 8 }
struct Attr { var fmt: MTLAttributeFormat; var buf: Int; var off: Int; var size: Int }
struct Cfg { var name: String; var attrs: [Attr]; var strides: [Int]; var constAttr: Int? }
let cfgs: [Cfg] = [
 Cfg(name: "A interleaved unorm/snorm/half/short/ushort", attrs: [Attr(fmt:.uchar4Normalized,buf:1,off:0,size:4), Attr(fmt:.short3Normalized,buf:1,off:4,size:6), Attr(fmt:.half2,buf:1,off:12,size:4), Attr(fmt:.short2,buf:1,off:16,size:4), Attr(fmt:.ushort4,buf:1,off:20,size:8)], strides:[0,28], constAttr:nil),
 Cfg(name: "B separate half4/float3/uchar2n/int2/uchar4", attrs: [Attr(fmt:.half4,buf:1,off:0,size:8), Attr(fmt:.float3,buf:2,off:0,size:12), Attr(fmt:.uchar2Normalized,buf:3,off:0,size:2), Attr(fmt:.int2,buf:4,off:0,size:8), Attr(fmt:.uchar4,buf:5,off:0,size:4)], strides:[0,8,12,2,8,4].enumerated().map{$0.element}, constAttr:nil),
 Cfg(name: "C bgra/char3n/half2/ushort2/uint4 + constant step on c", attrs: [Attr(fmt:.uchar4Normalized_bgra,buf:1,off:0,size:4), Attr(fmt:.char3Normalized,buf:1,off:4,size:3), Attr(fmt:.half2,buf:2,off:0,size:4), Attr(fmt:.ushort2,buf:1,off:8,size:4), Attr(fmt:.uint4,buf:1,off:12,size:16)], strides:[0,28,4], constAttr:2),
]
func comps(_ f: MTLAttributeFormat) -> Int { switch f { case .uchar4Normalized,.uchar4Normalized_bgra,.half4,.ushort4,.uint4,.uchar4: return 4; case .short3Normalized,.float3,.char3Normalized: return 3; case .half2,.short2,.ushort2,.uchar2Normalized,.int2: return 2; default: return 1 } }
var failed = 0
for cfg in cfgs {
  // vertex buffers
  var raw = [[UInt8]](repeating: [], count: 6)
  let nbuf = cfg.strides.count
  for b in 1..<nbuf { raw[b] = (0..<(cfg.strides[b] * N + 8)).map { _ in UInt8(rnd() & 255) } }
  // make half / float fields valid: overwrite with known values
  func put16(_ b: Int, _ at: Int, _ v: UInt16) { raw[b][at] = UInt8(v & 255); raw[b][at+1] = UInt8(v >> 8) }
  func put32f(_ b: Int, _ at: Int, _ v: Float) { var x = v; withUnsafeBytes(of: &x) { for i in 0..<4 { raw[b][at+i] = $0[i] } } }
  for i in 0..<N { for (ai, a) in cfg.attrs.enumerated() {
    let base = i * cfg.strides[a.buf] + a.off
    if a.fmt == .half2 || a.fmt == .half4 { for k in 0..<comps(a.fmt) { put16(a.buf, base + 2*k, halves[Int(rnd()) % halves.count]) } }
    if a.fmt == .float3 { for k in 0..<3 { put32f(a.buf, base + 4*k, Float(Int(rnd() % 2001) - 1000) / 8) } }
    _ = ai } }
  // expected
  var exp = [Float](repeating: 0, count: N * 16)
  for i in 0..<N {
    var o = i * 16
    for (ai, a) in cfg.attrs.enumerated() {
      let idx = (cfg.constAttr == ai) ? 0 : i
      let p = idx * cfg.strides[a.buf] + a.off
      let r = raw[a.buf]
      func u8(_ k: Int) -> Float { Float(r[p + k]) }
      func s8(_ k: Int) -> Float { Float(Int8(bitPattern: r[p + k])) }
      func u16(_ k: Int) -> UInt16 { UInt16(r[p+2*k]) | UInt16(r[p+2*k+1]) << 8 }
      func s16(_ k: Int) -> Float { Float(Int16(bitPattern: u16(k))) }
      func u32(_ k: Int) -> UInt32 { var v: UInt32 = 0; for q in 0..<4 { v |= UInt32(r[p+4*k+q]) << (8*UInt32(q)) }; return v }
      var v: [Float] = []
      switch a.fmt {
      case .uchar4Normalized: v = (0..<4).map { u8($0) / 255 }
      case .uchar4Normalized_bgra: let t = (0..<4).map { u8($0) / 255 }; v = [t[2], t[1], t[0], t[3]]
      case .short3Normalized: v = (0..<3).map { max(s16($0) / 32767, -1) } + [1]
      case .char3Normalized: v = (0..<3).map { max(s8($0) / 127, -1) } + [1]
      case .half2: v = (0..<2).map { h2f(u16($0)) }
      case .half4: v = (0..<4).map { h2f(u16($0)) }
      case .short2: v = (0..<2).map { s16($0) }
      case .ushort2: v = (0..<2).map { Float(u16($0)) }
      case .ushort4: v = (0..<4).map { Float(u16($0)) }
      case .float3: v = (0..<3).map { k in Float(bitPattern: u32(k)) }
      case .uchar2Normalized: v = (0..<2).map { u8($0) / 255 }
      case .int2: v = (0..<2).map { k in Float(Int32(bitPattern: u32(k))) }
      case .uchar4: v = (0..<4).map { u8($0) }
      case .uint4: v = (0..<4).map { k in Float(u32(k)) }
      default: v = []
      }
      // pad to the kernel type: a float4 (pad w=1), b float3, c half2, d int2, e uint4 (pad w=1)
      let want = [4,3,2,2,4][ai]
      while v.count < want { v.append(v.count == 3 ? 1 : 0) }
      for k in 0..<want { exp[o + k] = v[k] }
      o += want
    }
  }
  for mode in ["shared", "private"] {
    let d = MTLStageInputOutputDescriptor()
    for (ai, a) in cfg.attrs.enumerated() { d.attributes[ai].format = a.fmt; d.attributes[ai].bufferIndex = a.buf + 10; d.attributes[ai].offset = a.off }
    for b in 1..<nbuf { d.layouts[b + 10].stride = cfg.strides[b]; d.layouts[b + 10].stepFunction = .threadPositionInGridX; d.layouts[b + 10].stepRate = 1 }
    if let c = cfg.constAttr { d.layouts[cfg.attrs[c].buf + 10].stepFunction = .constant }
    let cd = MTLComputePipelineDescriptor(); cd.computeFunction = lib.makeFunction(name: "sitest")!; cd.stageInputDescriptor = d
    let ps = try! dev.makeComputePipelineState(descriptor: cd, options: [], reflection: nil)
    let q = dev.makeCommandQueue()!; let cb = q.makeCommandBuffer()!
    var vbufs: [MTLBuffer?] = [nil]
    for b in 1..<nbuf {
      let sh = dev.makeBuffer(bytes: raw[b], length: raw[b].count, options: .storageModeShared)!
      if mode == "shared" { vbufs.append(sh) } else {
        let pv = dev.makeBuffer(length: raw[b].count, options: .storageModePrivate)!
        let bl = cb.makeBlitCommandEncoder()!; bl.copy(from: sh, sourceOffset: 0, to: pv, destinationOffset: 0, size: raw[b].count); bl.endEncoding(); vbufs.append(pv) } }
    let out = dev.makeBuffer(length: N * 16 * 4, options: .storageModeShared)!
    memset(out.contents(), 0, N * 64)
    let e = cb.makeComputeCommandEncoder()!
    e.setComputePipelineState(ps); e.setBuffer(out, offset: 0, index: 0)
    for b in 1..<nbuf { e.setBuffer(vbufs[b]!, offset: 0, index: b + 10) }
    e.setStageInRegion(MTLRegionMake1D(0, N))
    e.dispatchThreads(MTLSize(width: N, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))
    e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    let got = Array(UnsafeBufferPointer(start: out.contents().assumingMemoryBound(to: Float.self), count: N * 16))
    var bad = 0; var first = ""
    for i in 0..<(N*16) where i % 16 < 15 { if abs(got[i] - exp[i]) > 1e-3 * max(1, abs(exp[i])) { bad += 1; if first.isEmpty { first = "vertex \(i/16) lane \(i%16): got \(got[i]) want \(exp[i])" } } }
    print("\(cfg.name) [\(mode)]: \(bad == 0 ? "PASS" : "FAIL \(bad)/\(N*15) \(first)")")
    if bad != 0 { failed += 1 }
  }
}
print(failed == 0 ? "ALL PASS" : "FAILED \(failed)")
