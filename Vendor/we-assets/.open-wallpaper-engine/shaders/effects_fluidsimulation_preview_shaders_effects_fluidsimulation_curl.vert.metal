#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 v_TexCoordLeftTop [[user(locn0)]];
    float4 v_TexCoordRightBottom [[user(locn1)]];
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
    float2 texelSize = float2(1.0) / g_Texture0Resolution.xy;
    out.v_TexCoordLeftTop = in.a_TexCoord.xyxy;
    out.v_TexCoordRightBottom = in.a_TexCoord.xyxy;
    out.v_TexCoordLeftTop.x -= texelSize.x;
    out.v_TexCoordLeftTop.w += texelSize.y;
    out.v_TexCoordRightBottom.x += texelSize.x;
    out.v_TexCoordRightBottom.w -= texelSize.y;
    return out;
}

