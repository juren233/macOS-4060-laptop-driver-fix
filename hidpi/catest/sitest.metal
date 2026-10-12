#include <metal_stdlib>
using namespace metal;
struct In { float4 a [[attribute(0)]]; float3 b [[attribute(1)]]; half2 c [[attribute(2)]]; int2 d [[attribute(3)]]; uint4 e [[attribute(4)]]; };
kernel void sitest(In in [[stage_in]], uint tid [[thread_position_in_grid]], device float *out [[buffer(0)]]) {
    device float *o = out + tid * 16;
    o[0] = in.a.x; o[1] = in.a.y; o[2] = in.a.z; o[3] = in.a.w;
    o[4] = in.b.x; o[5] = in.b.y; o[6] = in.b.z;
    o[7] = float(in.c.x); o[8] = float(in.c.y);
    o[9] = float(in.d.x); o[10] = float(in.d.y);
    o[11] = float(in.e.x); o[12] = float(in.e.y); o[13] = float(in.e.z); o[14] = float(in.e.w);
}
