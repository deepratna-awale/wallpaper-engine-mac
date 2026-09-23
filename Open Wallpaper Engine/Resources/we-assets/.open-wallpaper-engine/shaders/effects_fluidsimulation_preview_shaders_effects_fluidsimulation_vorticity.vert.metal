#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float2 v_TexCoord [[user(locn0)]];
    float4 v_TexCoordLeftTop [[user(locn1)]];
    float4 v_TexCoordRightBottom [[user(locn2)]];
    float4 v_PointerUV [[user(locn3)]];
    float4 v_PointerUVLast [[user(locn4)]];
    float2 v_PointDelta [[user(locn5)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

static inline __attribute__((always_inline))
float4 mul(thread const float4& value, thread const float4x4& matrix)
{
    return matrix * value;
}

vertex main0_out main0(main0_in in [[stage_in]], constant float4& g_Texture0Resolution [[buffer(0)]], constant float2& g_PointerPosition [[buffer(1)]], constant float2& g_PointerPositionLast [[buffer(2)]], constant float4x4& g_EffectTextureProjectionMatrixInverse [[buffer(3)]], constant float& u_CursorInfluence [[buffer(4)]])
{
    main0_out out = {};
    out.gl_Position = float4(in.a_Position, 1.0);
    out.v_TexCoord = in.a_TexCoord;
    float2 texelSize = float2(1.0) / g_Texture0Resolution.xy;
    out.v_TexCoordLeftTop = in.a_TexCoord.xyxy;
    out.v_TexCoordRightBottom = in.a_TexCoord.xyxy;
    out.v_TexCoordLeftTop.x -= texelSize.x;
    out.v_TexCoordLeftTop.w += texelSize.y;
    out.v_TexCoordRightBottom.x += texelSize.x;
    out.v_TexCoordRightBottom.w -= texelSize.y;
    float2 pointer = g_PointerPosition;
    pointer.y = 1.0 - pointer.y;
    float2 pointerLast = g_PointerPositionLast;
    pointerLast.y = 1.0 - pointerLast.y;
    float4 preTransformPoint = float4((pointer * 2.0) - float2(1.0), 0.0, 1.0);
    float4 preTransformPointLast = float4((pointerLast * 2.0) - float2(1.0), 0.0, 1.0);
    float4 param = preTransformPoint;
    float4x4 param_1 = g_EffectTextureProjectionMatrixInverse;
    float3 _129 = mul(param, param_1).xyw;
    out.v_PointerUV.x = _129.x;
    out.v_PointerUV.y = _129.y;
    out.v_PointerUV.z = _129.z;
    float4 _138 = out.v_PointerUV;
    float2 _140 = _138.xy * 0.5;
    out.v_PointerUV.x = _140.x;
    out.v_PointerUV.y = _140.y;
    float _146 = out.v_PointerUV.z;
    float4 _147 = out.v_PointerUV;
    float2 _150 = _147.xy / float2(_146);
    out.v_PointerUV.x = _150.x;
    out.v_PointerUV.y = _150.y;
    float4 param_2 = preTransformPointLast;
    float4x4 param_3 = g_EffectTextureProjectionMatrixInverse;
    float3 _161 = mul(param_2, param_3).xyw;
    out.v_PointerUVLast.x = _161.x;
    out.v_PointerUVLast.y = _161.y;
    out.v_PointerUVLast.z = _161.z;
    float4 _168 = out.v_PointerUVLast;
    float2 _170 = _168.xy * 0.5;
    out.v_PointerUVLast.x = _170.x;
    out.v_PointerUVLast.y = _170.y;
    float _176 = out.v_PointerUVLast.z;
    float4 _177 = out.v_PointerUVLast;
    float2 _180 = _177.xy / float2(_176);
    out.v_PointerUVLast.x = _180.x;
    out.v_PointerUVLast.y = _180.y;
    out.v_PointerUV.w = g_Texture0Resolution.y / (-g_Texture0Resolution.x);
    float moveAmt = length(g_PointerPosition - g_PointerPositionLast);
    out.v_PointDelta.x = (step(0.0, moveAmt) * 0.5) + ((moveAmt * 10.0) * u_CursorInfluence);
    out.v_PointDelta.y = 60.0 / fast::max(9.9999997473787516355514526367188e-05, u_CursorInfluence);
    out.v_PointerUV.w *= (-out.v_PointDelta.y);
    out.v_PointerUVLast.w = out.v_PointerUV.w;
    float4 _226 = out.v_PointerUV;
    float2 _229 = _226.xy + float2(0.5);
    out.v_PointerUV.x = _229.x;
    out.v_PointerUV.y = _229.y;
    out.v_PointerUV.y = 1.0 - out.v_PointerUV.y;
    out.v_PointerUV.z = 1.0;
    float4 _239 = out.v_PointerUVLast;
    float2 _242 = _239.xy + float2(0.5);
    out.v_PointerUVLast.x = _242.x;
    out.v_PointerUVLast.y = _242.y;
    out.v_PointerUVLast.y = 1.0 - out.v_PointerUVLast.y;
    out.v_PointerUVLast.z = 1.0;
    return out;
}

