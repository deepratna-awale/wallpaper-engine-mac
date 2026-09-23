#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float2 v_TexCoord [[user(locn0)]];
    float4 v_NormalCoord [[user(locn1)]];
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

vertex main0_out main0(main0_in in [[stage_in]], constant float4x4& g_ModelViewProjectionMatrix [[buffer(0)]], constant float& g_Time [[buffer(1)]], constant float& g_WaveSpeed [[buffer(2)]])
{
    main0_out out = {};
    float4 param = float4(in.a_Position, 1.0);
    float4x4 param_1 = g_ModelViewProjectionMatrix;
    out.gl_Position = mul(param, param_1);
    out.v_TexCoord = in.a_TexCoord;
    float2 _58 = (in.a_TexCoord * float2(1.0, 0.300000011920928955078125)) * 0.699999988079071044921875;
    out.v_NormalCoord.x = _58.x;
    out.v_NormalCoord.y = _58.y;
    out.v_NormalCoord.x -= (g_Time * g_WaveSpeed);
    float2 _78 = (in.a_TexCoord * float2(1.0, 0.699999988079071044921875)) * 0.300000011920928955078125;
    out.v_NormalCoord.z = _78.x;
    out.v_NormalCoord.w = _78.y;
    out.v_NormalCoord.z -= ((g_Time * g_WaveSpeed) * 0.5);
    return out;
}

