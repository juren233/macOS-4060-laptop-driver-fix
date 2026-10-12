// Regression test for fix 23: writes into a CAMetalLayer drawable with framebufferOnly = NO.
// QuartzCore hands such a drawable usage Unknown(0); Apple's drivers read that as "all usages", the plugin must too.
// Build/run:  swiftc -O drawable-writes.swift -o drawable-writes && ./drawable-writes     (every line must say OK)
// Expected picture everywhere: top half RED, bottom half BLUE (row 0 = top). Core Image needs isFlipped = true for that:
// isFlipped = false puts the image's LOWER-left pixel at row 0 (documented in CIRenderDestination.h) - not a bug.
import Metal
import QuartzCore
import CoreImage
import Foundation

let W = 640, H = 480
let dev = MTLCreateSystemDefaultDevice()!
let q = dev.makeCommandQueue()!
let msl = """
#include <metal_stdlib>
using namespace metal;
struct V { float4 p [[position]]; };
vertex V vs(uint i [[vertex_id]]) { float2 xy[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) }; V v; v.p = float4(xy[i], 0, 1); return v; }
fragment float4 fs(V in [[stage_in]], constant float &h [[buffer(0)]]) { return in.p.y < h * 0.5 ? float4(1,0,0,1) : float4(0,0,1,1); }
kernel void ck(texture2d<float, access::write> o [[texture(0)]], uint2 g [[thread_position_in_grid]]) { o.write(g.y < o.get_height() / 2 ? float4(1,0,0,1) : float4(0,0,1,1), g); }
"""
let lib = try! dev.makeLibrary(source: msl, options: nil)
let cps = try! dev.makeComputePipelineState(function: lib.makeFunction(name: "ck")!)
let rd = MTLRenderPipelineDescriptor(); rd.vertexFunction = lib.makeFunction(name: "vs"); rd.fragmentFunction = lib.makeFunction(name: "fs"); rd.colorAttachments[0].pixelFormat = .bgra8Unorm
let rps = try! dev.makeRenderPipelineState(descriptor: rd)

func drawable(framebufferOnly: Bool) -> CAMetalDrawable {
  let l = CAMetalLayer(); l.device = dev; l.pixelFormat = .bgra8Unorm; l.framebufferOnly = framebufferOnly; l.drawableSize = CGSize(width: W, height: H); return l.nextDrawable()!
}
func name(_ p: [UInt8]) -> String { p[2] > 200 && p[0] < 60 ? "RED" : (p[0] > 200 && p[2] < 60 ? "BLUE" : "other\(p)") }
var failed = 0
func check(_ label: String, _ d: CAMetalDrawable) {
  var a = [UInt8](repeating: 0, count: 4), b = a
  d.texture.getBytes(&a, bytesPerRow: W * 4, from: MTLRegionMake2D(W / 2, 10, 1, 1), mipmapLevel: 0)
  d.texture.getBytes(&b, bytesPerRow: W * 4, from: MTLRegionMake2D(W / 2, H - 10, 1, 1), mipmapLevel: 0)
  let ok = name(a) == "RED" && name(b) == "BLUE"; if !ok { failed += 1 }
  print("\(ok ? "OK  " : "FAIL") \(label.padding(toLength: 52, withPad: " ", startingAt: 0)) top \(name(a)) / bottom \(name(b))")
}
func finish(_ d: CAMetalDrawable, _ cb: MTLCommandBuffer) { cb.present(d); cb.commit(); cb.waitUntilCompleted() }

do { let d = drawable(framebufferOnly: false); let cb = q.makeCommandBuffer()!
  let rp = MTLRenderPassDescriptor(); rp.colorAttachments[0].texture = d.texture; rp.colorAttachments[0].loadAction = .dontCare; rp.colorAttachments[0].storeAction = .store
  let e = cb.makeRenderCommandEncoder(descriptor: rp)!; e.setRenderPipelineState(rps); var h = Float(H); e.setFragmentBytes(&h, length: 4, index: 0)
  e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); e.endEncoding(); finish(d, cb); check("render pass, framebufferOnly=NO", d) }
do { let d = drawable(framebufferOnly: false); let cb = q.makeCommandBuffer()!; let e = cb.makeComputeCommandEncoder()!
  e.setComputePipelineState(cps); e.setTexture(d.texture, index: 0)
  e.dispatchThreads(MTLSize(width: W, height: H, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1)); e.endEncoding(); finish(d, cb)
  check("compute write, framebufferOnly=NO (was dropped)", d) }
var buf = [UInt8](repeating: 0, count: W * H * 4)
for r in 0..<H { for c in 0..<W { let o = (r * W + c) * 4; if r < H / 2 { buf[o + 2] = 255 } else { buf[o] = 255 }; buf[o + 3] = 255 } }
do { let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false); td.usage = [.shaderRead]
  let s = dev.makeTexture(descriptor: td)!; s.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0, withBytes: buf, bytesPerRow: W * 4)
  let d = drawable(framebufferOnly: false); let cb = q.makeCommandBuffer()!; let b = cb.makeBlitCommandEncoder()!; b.copy(from: s, to: d.texture); b.endEncoding(); finish(d, cb)
  check("blit copy, framebufferOnly=NO", d) }
for flipped in [true] {
  let d = drawable(framebufferOnly: false); let cb = q.makeCommandBuffer()!
  let img = CIImage(bitmapData: Data(buf), bytesPerRow: W * 4, size: CGSize(width: W, height: H), format: .BGRA8, colorSpace: nil)
  let dest = CIRenderDestination(mtlTexture: d.texture, commandBuffer: cb); dest.isFlipped = flipped
  try! CIContext(mtlDevice: dev).startTask(toRender: img, to: dest); finish(d, cb)
  check("Core Image isFlipped=\(flipped), framebufferOnly=NO", d) }
print(failed == 0 ? "ALL OK" : "\(failed) FAILED"); exit(failed == 0 ? 0 : 1)
