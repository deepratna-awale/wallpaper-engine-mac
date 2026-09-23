#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float2 v_TexCoord [[user(locn0)]];
    float4 v_PointerUV [[user(locn1)]];
    float4 v_PointerUVLast [[user(locn2)]];
    float2 v_PointDelta [[user(locn3)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant float2& g_PointerPosition [[buffer(0)]], constant float2& g_PointerPositionLast [[buffer(1)]], constant float4x4& g_EffectTextureProjectionMatrixInverse [[buffer(2)]], constant float4& g_Texture0Resolution [[buffer(3)]], constant float& g_RippleScale [[buffer(4)]])
{
    main0_out out = {};
    out.gl_Position = float4(in.a_Position, 1.0);
    out.v_TexCoord = in.a_TexCoord;
    float2 pointer = g_PointerPosition;
    pointer.y = 1.0 - pointer.y;
    float2 pointerLast = g_PointerPositionLast;
    pointerLast.y = 1.0 - pointerLast.y;
    float4 preTransformPoint = float4((pointer * 2.0) - float2(1.0), 0.0, 1.0);
    float4 preTransformPointLast = float4((pointerLast * 2.0) - float2(1.0), 0.0, 1.0);
    float3 _76 = (preTransformPoint * g_EffectTextureProjectionMatrixInverse).xyw;
    out.v_PointerUV.x = _76.x;
    out.v_PointerUV.y = _76.y;
    out.v_PointerUV.z = _76.z;
    float4 _87 = out.v_PointerUV;
    float2 _89 = _87.xy * 0.5;
    out.v_PointerUV.x = _89.x;
    out.v_PointerUV.y = _89.y;
    float3 _98 = (preTransformPointLast * g_EffectTextureProjectionMatrixInverse).xyw;
    out.v_PointerUVLast.x = _98.x;
    out.v_PointerUVLast.y = _98.y;
    out.v_PointerUVLast.z = _98.z;
    float4 _105 = out.v_PointerUVLast;
    float2 _107 = _105.xy * 0.5;
    out.v_PointerUVLast.x = _107.x;
    out.v_PointerUVLast.y = _107.y;
    out.v_PointerUV.w = g_Texture0Resolution.y / (-g_Texture0Resolution.x);
    out.v_PointDelta.x = length(g_PointerPosition - g_PointerPositionLast);
    out.v_PointDelta.x *= 100.0;
    out.v_PointDelta.y = 60.0 / fast::max(9.9999997473787516355514526367188e-05, g_RippleScale);
    out.v_PointerUV.w *= (-out.v_PointDelta.y);
    out.v_PointerUVLast.w = out.v_PointerUV.w;
    return out;
}

