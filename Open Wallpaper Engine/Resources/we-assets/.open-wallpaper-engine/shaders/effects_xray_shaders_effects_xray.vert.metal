#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 v_TexCoord [[user(locn0)]];
    float4 v_PointerUV [[user(locn1)]];
    float v_PointerScale [[user(locn2)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant float4x4& g_ModelViewProjectionMatrix [[buffer(0)]], constant float4& g_Texture1Resolution [[buffer(1)]], constant float2& g_PointerPosition [[buffer(2)]], constant float4x4& g_EffectTextureProjectionMatrixInverse [[buffer(3)]], constant float4& g_Texture0Resolution [[buffer(4)]], constant float& g_PointerScale [[buffer(5)]])
{
    main0_out out = {};
    out.gl_Position = float4(in.a_Position, 1.0) * g_ModelViewProjectionMatrix;
    out.v_TexCoord.x = in.a_TexCoord.x;
    out.v_TexCoord.y = in.a_TexCoord.y;
    float _44 = out.v_TexCoord.x;
    float _56 = out.v_TexCoord.y;
    float2 _64 = float2((_44 * g_Texture1Resolution.z) / g_Texture1Resolution.x, (_56 * g_Texture1Resolution.w) / g_Texture1Resolution.y);
    out.v_TexCoord.z = _64.x;
    out.v_TexCoord.w = _64.y;
    float2 pointer = g_PointerPosition;
    pointer.y = 1.0 - pointer.y;
    float3 _92 = (float4((pointer * 2.0) - float2(1.0), 0.0, 1.0) * g_EffectTextureProjectionMatrixInverse).xyw;
    out.v_PointerUV.x = _92.x;
    out.v_PointerUV.y = _92.y;
    out.v_PointerUV.z = _92.z;
    float4 _100 = out.v_PointerUV;
    float2 _102 = _100.xy * 0.5;
    out.v_PointerUV.x = _102.x;
    out.v_PointerUV.y = _102.y;
    out.v_PointerUV.w = g_Texture0Resolution.y / (-g_Texture0Resolution.x);
    out.v_PointerScale = mix(999.0, 1.0 / g_PointerScale, step(0.001000000047497451305389404296875, g_PointerScale));
    return out;
}

