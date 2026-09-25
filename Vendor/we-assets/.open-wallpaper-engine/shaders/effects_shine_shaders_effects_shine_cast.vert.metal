#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 v_TexCoord01 [[user(locn0)]];
    float4 v_TexCoord23 [[user(locn1)]];
    float4 v_TexCoord45 [[user(locn2)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

static inline __attribute__((always_inline))
float2 rotateVec2(thread const float2& value, thread const float& angle)
{
    float s = sin(angle);
    float c = cos(angle);
    return float2((value.x * c) - (value.y * s), (value.x * s) + (value.y * c));
}

vertex main0_out main0(main0_in in [[stage_in]], constant float& g_Time [[buffer(0)]], constant float& g_Speed [[buffer(1)]], constant float4& g_Texture0Resolution [[buffer(2)]])
{
    main0_out out = {};
    out.gl_Position = float4(in.a_Position, 1.0);
    out.v_TexCoord01.x = in.a_TexCoord.x;
    out.v_TexCoord01.y = in.a_TexCoord.y;
    float2 param = float2(0.0, 0.5);
    float param_1 = g_Time * g_Speed;
    float2 baseDirection = rotateVec2(param, param_1);
    float ratio = g_Texture0Resolution.x / g_Texture0Resolution.y;
    out.v_TexCoord01.w *= ratio;
    float4 _101 = out.v_TexCoord23;
    float2 _103 = _101.yw * ratio;
    out.v_TexCoord23.y = _103.x;
    out.v_TexCoord23.w = _103.y;
    float4 _110 = out.v_TexCoord45;
    float2 _112 = _110.yw * ratio;
    out.v_TexCoord45.y = _112.x;
    out.v_TexCoord45.w = _112.y;
    return out;
}

