#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant float4x4& g_AltViewProjectionMatrix [[buffer(0)]], constant float4x4& g_ViewProjectionMatrix [[buffer(1)]])
{
    main0_out out = {};
    out.gl_Position = (float4(in.a_Position, 1.0) * g_AltViewProjectionMatrix) * g_ViewProjectionMatrix;
    return out;
}

