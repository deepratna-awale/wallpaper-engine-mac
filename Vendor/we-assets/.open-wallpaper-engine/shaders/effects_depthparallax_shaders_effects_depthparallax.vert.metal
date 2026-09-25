#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 v_TexCoord [[user(locn0)]];
    float2 v_ParallaxOffset [[user(locn1)]];
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

static inline __attribute__((always_inline))
float3 mul(thread const float3& value, thread const float3x3& matrix)
{
    return matrix * value;
}

vertex main0_out main0(main0_in in [[stage_in]], constant float4x4& g_ModelViewProjectionMatrix [[buffer(0)]], constant float4& g_Texture1Resolution [[buffer(1)]], constant float4x4& g_EffectTextureProjectionMatrixInverse [[buffer(2)]], constant float2& g_ParallaxPosition [[buffer(3)]])
{
    main0_out out = {};
    float4 param = float4(in.a_Position, 1.0);
    float4x4 param_1 = g_ModelViewProjectionMatrix;
    out.gl_Position = mul(param, param_1);
    out.v_TexCoord.x = in.a_TexCoord.x;
    out.v_TexCoord.y = in.a_TexCoord.y;
    float2 _92 = float2((in.a_TexCoord.x * g_Texture1Resolution.z) / g_Texture1Resolution.x, (in.a_TexCoord.y * g_Texture1Resolution.w) / g_Texture1Resolution.y);
    out.v_TexCoord.z = _92.x;
    out.v_TexCoord.w = _92.y;
    float3x3 rot = float3x3(g_EffectTextureProjectionMatrixInverse[0].xyz, g_EffectTextureProjectionMatrixInverse[1].xyz, g_EffectTextureProjectionMatrixInverse[2].xyz);
    float3 param_2 = float3(1.0, 0.0, 0.0);
    float3x3 param_3 = rot;
    float2 projectedDirX = mul(param_2, param_3).xy;
    float3 param_4 = float3(0.0, 1.0, 0.0);
    float3x3 param_5 = rot;
    float2 projectedDirY = mul(param_4, param_5).xy;
    projectedDirX = fast::normalize(projectedDirX);
    projectedDirY = fast::normalize(projectedDirY);
    float2 prlxInput = (g_ParallaxPosition * 2.0) - float2(1.0);
    out.v_ParallaxOffset = (projectedDirX * prlxInput.x) + (projectedDirY * prlxInput.y);
    out.v_ParallaxOffset = (out.v_ParallaxOffset * 0.5) + float2(0.5);
    return out;
}

