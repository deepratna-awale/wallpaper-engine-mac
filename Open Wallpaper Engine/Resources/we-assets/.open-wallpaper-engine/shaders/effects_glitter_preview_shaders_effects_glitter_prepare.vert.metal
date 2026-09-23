#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float2 v_TexCoord [[user(locn0)]];
    float2 v_NoiseCoord [[user(locn1)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant float4& g_Texture0Resolution [[buffer(0)]])
{
    main0_out out = {};
    out.gl_Position = float4(in.a_Position, 1.0);
    out.v_TexCoord = in.a_TexCoord;
    out.v_NoiseCoord = float2(in.a_TexCoord.x * (g_Texture0Resolution.x / g_Texture0Resolution.y), in.a_TexCoord.y) * 5.0;
    return out;
}

