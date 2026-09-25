#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 v_TexCoordNoise [[user(locn0)]];
    float3 v_Params [[user(locn1)]];
    float4 v_TexCoord [[user(locn2)]];
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
float2 rotateVec2(thread const float2& value, thread const float& angle)
{
    float s = sin(angle);
    float c = cos(angle);
    return float2((value.x * c) - (value.y * s), (value.x * s) + (value.y * c));
}

vertex main0_out main0(main0_in in [[stage_in]], constant float4x4& g_ModelViewProjectionMatrix [[buffer(0)]], constant float4& g_Texture0Resolution [[buffer(1)]], constant float& g_Ratio [[buffer(2)]], constant float& g_Direction [[buffer(3)]], constant float& g_NoiseScale [[buffer(4)]], constant float& g_Strength [[buffer(5)]])
{
    main0_out out = {};
    out.v_TexCoord.z = 0.0;
    out.v_TexCoord.w = 0.0;
    float4 param = float4(in.a_Position, 1.0);
    float4x4 param_1 = g_ModelViewProjectionMatrix;
    out.gl_Position = mul(param, param_1);
    float aspect = (g_Texture0Resolution.z / g_Texture0Resolution.w) * g_Ratio;
    float2 param_2 = float2(1.0 / aspect, aspect);
    float param_3 = g_Direction;
    float2 _113 = rotateVec2(param_2, param_3);
    out.v_TexCoordNoise.z = _113.x;
    out.v_TexCoordNoise.w = _113.y;
    float2 _123 = in.a_TexCoord * g_NoiseScale;
    out.v_TexCoordNoise.x = _123.x;
    out.v_TexCoordNoise.y = _123.y;
    float2 param_4 = in.a_TexCoord;
    float param_5 = g_Direction;
    float2 _134 = rotateVec2(param_4, param_5);
    out.v_Params.x = _134.x;
    out.v_Params.y = _134.y;
    out.v_Params.z = (g_Strength * g_Strength) * 0.004999999888241291046142578125;
    out.v_TexCoord.x = in.a_TexCoord.x;
    out.v_TexCoord.y = in.a_TexCoord.y;
    return out;
}

