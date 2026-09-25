#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 v_TexCoord [[user(locn0)]];
    float4 v_TexCoordIris [[user(locn1)]];
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

vertex main0_out main0(main0_in in [[stage_in]], constant float4x4& g_ModelViewProjectionMatrix [[buffer(0)]], constant float& g_Time [[buffer(1)]], constant float& g_Speed [[buffer(2)]], constant float& g_Rough [[buffer(3)]], constant float& g_NoiseAmount [[buffer(4)]], constant float2& g_Scale [[buffer(5)]])
{
    main0_out out = {};
    float4 param = float4(in.a_Position, 1.0);
    float4x4 param_1 = g_ModelViewProjectionMatrix;
    out.gl_Position = mul(param, param_1);
    out.v_TexCoord = in.a_TexCoord.xyxy;
    float dt = floor(g_Time * g_Speed);
    float ft = fract(g_Time * g_Speed);
    float2 da0 = float2(sin(1.7000000476837158203125 * dt)) + sin(float2(2.2999999523162841796875 * dt) + float2(1.0, 2.0));
    float2 da1 = float2(sin(1.7000000476837158203125 * (dt + 1.0))) + sin(float2(2.2999999523162841796875 * (dt + 1.0)) + float2(1.0, 2.0));
    float2 da = mix(da0, da1, float2(smoothstep(1.0 - g_Rough, 1.0, ft)));
    da.x += (sin(g_Time * g_Speed) * g_NoiseAmount);
    da.y += (cos(g_Time * g_Speed) * g_NoiseAmount);
    da *= (g_Scale * 0.001000000047497451305389404296875);
    out.v_TexCoordIris = out.v_TexCoord + da.xyxy;
    return out;
}

