#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 v_TexCoord [[user(locn0)]];
    float4 v_TexCoordNoise [[user(locn1)]];
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

vertex main0_out main0(main0_in in [[stage_in]], constant float4x4& g_ModelViewProjectionMatrix [[buffer(0)]], constant float4& g_Texture0Resolution [[buffer(1)]], constant float& g_Time [[buffer(2)]], constant float& g_NoiseScale [[buffer(3)]])
{
    main0_out out = {};
    float4 param = float4(in.a_Position, 1.0);
    float4x4 param_1 = g_ModelViewProjectionMatrix;
    out.gl_Position = mul(param, param_1);
    float aspect = g_Texture0Resolution.z / g_Texture0Resolution.w;
    float t = fract(g_Time);
    out.v_TexCoord = in.a_TexCoord.xyxy;
    float2 _75 = (in.a_TexCoord + float2(t)) * g_NoiseScale;
    out.v_TexCoordNoise.x = _75.x;
    out.v_TexCoordNoise.y = _75.y;
    float2 _91 = ((in.a_TexCoord - float2(t * 2.5)) * g_NoiseScale) * 0.519999980926513671875;
    out.v_TexCoordNoise.z = _91.x;
    out.v_TexCoordNoise.w = _91.y;
    out.v_TexCoordNoise *= float4(aspect, 1.0, aspect, 1.0);
    return out;
}

