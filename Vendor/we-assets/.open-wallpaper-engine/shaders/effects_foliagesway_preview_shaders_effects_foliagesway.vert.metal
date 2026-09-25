#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float2 v_TexCoord [[user(locn0)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

static inline __attribute__((always_inline))
float4 _pow(thread const float4& value, thread const float& exponent)
{
    return powr(value, float4(exponent));
}

static inline __attribute__((always_inline))
float4 mul(thread const float4& value, thread const float4x4& matrix)
{
    return matrix * value;
}

vertex main0_out main0(main0_in in [[stage_in]], constant float& g_Phase [[buffer(0)]], constant float& g_Speed [[buffer(1)]], constant float& g_Time [[buffer(2)]], constant float& g_Power [[buffer(3)]], constant float4& g_CornerWeights [[buffer(4)]], constant float& g_Strength [[buffer(5)]], constant float2& g_DirectionWeights [[buffer(6)]], constant float4x4& g_ModelViewProjectionMatrix [[buffer(7)]])
{
    main0_out out = {};
    float3 position = in.a_Position;
    float4 sines = float4(g_Phase) + (float4(1.0, -0.16161616146564483642578125, 0.008333300240337848663330078125, -0.00019840999448206275701522827148438) * (g_Speed * g_Time));
    sines = sin(sines);
    float4 csines = float4(0.4000000059604644775390625 + g_Phase) + (float4(-0.5, 0.041666664183139801025390625, -0.001388887991197407245635986328125, 2.4801000108709558844566345214844e-05) * (g_Speed * g_Time));
    csines = sin(csines);
    float4 param = abs(sines);
    float param_1 = g_Power;
    sines = _pow(param, param_1) * sign(sines);
    float4 param_2 = abs(csines);
    float param_3 = g_Power;
    csines = _pow(param_2, param_3) * sign(csines);
    float weight = fast::clamp(((((g_CornerWeights.x * (1.0 - in.a_TexCoord.x)) * (1.0 - in.a_TexCoord.y)) + ((g_CornerWeights.y * in.a_TexCoord.x) * (1.0 - in.a_TexCoord.y))) + ((g_CornerWeights.z * in.a_TexCoord.x) * in.a_TexCoord.y)) + ((g_CornerWeights.w * (1.0 - in.a_TexCoord.x)) * in.a_TexCoord.y), 0.0, 1.0);
    position.x += (((dot(sines, float4(1.0)) * g_Strength) * weight) * g_DirectionWeights.x);
    position.y += (((dot(csines, float4(1.0)) * g_Strength) * weight) * g_DirectionWeights.y);
    float4 param_4 = float4(position, 1.0);
    float4x4 param_5 = g_ModelViewProjectionMatrix;
    out.gl_Position = mul(param_4, param_5);
    out.v_TexCoord = in.a_TexCoord;
    return out;
}

