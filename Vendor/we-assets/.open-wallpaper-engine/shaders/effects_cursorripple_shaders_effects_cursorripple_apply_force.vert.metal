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
    float _95 = out.v_PointerUV.z;
    float4 _96 = out.v_PointerUV;
    float2 _99 = _96.xy / float2(_95);
    out.v_PointerUV.x = _99.x;
    out.v_PointerUV.y = _99.y;
    float3 _108 = (preTransformPointLast * g_EffectTextureProjectionMatrixInverse).xyw;
    out.v_PointerUVLast.x = _108.x;
    out.v_PointerUVLast.y = _108.y;
    out.v_PointerUVLast.z = _108.z;
    float4 _115 = out.v_PointerUVLast;
    float2 _117 = _115.xy * 0.5;
    out.v_PointerUVLast.x = _117.x;
    out.v_PointerUVLast.y = _117.y;
    float _123 = out.v_PointerUVLast.z;
    float4 _124 = out.v_PointerUVLast;
    float2 _127 = _124.xy / float2(_123);
    out.v_PointerUVLast.x = _127.x;
    out.v_PointerUVLast.y = _127.y;
    out.v_PointerUV.w = g_Texture0Resolution.y / (-g_Texture0Resolution.x);
    out.v_PointDelta.x = length(g_PointerPosition - g_PointerPositionLast);
    out.v_PointDelta.x *= 100.0;
    out.v_PointDelta.y = 60.0 / fast::max(9.9999997473787516355514526367188e-05, g_RippleScale);
    out.v_PointerUV.w *= (-out.v_PointDelta.y);
    out.v_PointerUVLast.w = out.v_PointerUV.w;
    out.v_PointerUV.z = 1.0;
    float4 _172 = out.v_PointerUV;
    float2 _175 = _172.xy + float2(0.5);
    out.v_PointerUV.x = _175.x;
    out.v_PointerUV.y = _175.y;
    out.v_PointerUV.y = 1.0 - out.v_PointerUV.y;
    out.v_PointerUVLast.z = 1.0;
    float4 _185 = out.v_PointerUVLast;
    float2 _188 = _185.xy + float2(0.5);
    out.v_PointerUVLast.x = _188.x;
    out.v_PointerUVLast.y = _188.y;
    out.v_PointerUVLast.y = 1.0 - out.v_PointerUVLast.y;
    return out;
}

