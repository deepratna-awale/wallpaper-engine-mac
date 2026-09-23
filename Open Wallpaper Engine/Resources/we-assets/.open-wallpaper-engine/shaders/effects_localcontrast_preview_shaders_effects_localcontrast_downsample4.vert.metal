#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 v_TexCoord01 [[user(locn0)]];
    float4 v_TexCoord23 [[user(locn1)]];
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
    float2 offsets = float2(1.0) / g_Texture0Resolution.zw;
    float2 _41 = in.a_TexCoord - offsets;
    out.v_TexCoord01.x = _41.x;
    out.v_TexCoord01.y = _41.y;
    float2 _56 = in.a_TexCoord + float2(offsets.x, -offsets.y);
    out.v_TexCoord01.z = _56.x;
    out.v_TexCoord01.w = _56.y;
    float2 _71 = in.a_TexCoord + float2(-offsets.x, offsets.y);
    out.v_TexCoord23.x = _71.x;
    out.v_TexCoord23.y = _71.y;
    float2 _78 = in.a_TexCoord + offsets;
    out.v_TexCoord23.z = _78.x;
    out.v_TexCoord23.w = _78.y;
    return out;
}

