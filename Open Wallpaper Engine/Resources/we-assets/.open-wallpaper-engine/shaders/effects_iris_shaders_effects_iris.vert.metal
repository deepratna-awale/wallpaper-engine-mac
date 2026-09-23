#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 v_TexCoord [[user(locn0)]];
    float2 v_TexCoordIris [[user(locn1)]];
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

vertex main0_out main0(main0_in in [[stage_in]], constant float4x4& g_ModelViewProjectionMatrix [[buffer(0)]], constant float& g_Time [[buffer(1)]], constant float& g_Speed [[buffer(2)]], constant float& g_PhaseOffset [[buffer(3)]], constant float& g_Rough [[buffer(4)]], constant float& g_NoiseAmount [[buffer(5)]], constant float2& g_Scale [[buffer(6)]])
{
    main0_out out = {};
    float4 param = float4(in.a_Position, 1.0);
    float4x4 param_1 = g_ModelViewProjectionMatrix;
    out.gl_Position = mul(param, param_1);
    out.v_TexCoord = in.a_TexCoord.xyxy;
    float time = (g_Time * g_Speed) + g_PhaseOffset;
    float lowDt = floor(time);
    float2 motion2 = sin((float2(lowDt) + float2(0.0, 1.0)) * 1.89999997615814208984375);
    float4 motion4 = sin(((float4(lowDt) + float4(0.0, 0.0, 1.0, 1.0)) * 2.5) + float4(1.0, 2.0, 1.0, 2.0));
    float2 moveStart = motion2.xx + motion4.xy;
    float2 moveEnd = motion2.yy + motion4.zw;
    float2 da = mix(moveStart, moveEnd, float2(smoothstep(1.0 - g_Rough, 1.0, (cos(fract(time) * 3.141590118408203125) * (-0.5)) + 0.5)));
    da.x += (sin(time) * g_NoiseAmount);
    da.y += (cos(time) * g_NoiseAmount);
    da *= (g_Scale * 0.001000000047497451305389404296875);
    out.v_TexCoordIris = da;
    return out;
}

