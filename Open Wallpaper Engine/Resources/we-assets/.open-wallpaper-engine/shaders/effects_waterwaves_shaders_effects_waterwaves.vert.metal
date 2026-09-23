#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 v_TexCoord [[user(locn0)]];
    float2 v_Direction [[user(locn1)]];
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

vertex main0_out main0(main0_in in [[stage_in]], constant float4x4& g_ModelViewProjectionMatrix [[buffer(0)]], constant float& g_Direction [[buffer(1)]])
{
    main0_out out = {};
    float4 param = float4(in.a_Position, 1.0);
    float4x4 param_1 = g_ModelViewProjectionMatrix;
    out.gl_Position = mul(param, param_1);
    out.v_TexCoord = in.a_TexCoord.xyxy;
    float2 param_2 = float2(0.0, 1.0);
    float param_3 = g_Direction;
    out.v_Direction = rotateVec2(param_2, param_3);
    return out;
}

