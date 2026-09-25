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

static inline __attribute__((always_inline))
float2 applyFx(thread float2& v, constant float& g_Direction, constant float2& g_Offset, constant float2& g_Scale)
{
    float2 param = v - float2(0.5);
    float param_1 = g_Direction;
    v = rotateVec2(param, param_1);
    return ((v + g_Offset) * g_Scale) + float2(0.5);
}

vertex main0_out main0(main0_in in [[stage_in]], constant float& g_Direction [[buffer(0)]], constant float2& g_Offset [[buffer(1)]], constant float2& g_Scale [[buffer(2)]], constant float4x4& g_ModelViewProjectionMatrix [[buffer(3)]])
{
    main0_out out = {};
    float3 position = in.a_Position;
    float4 param = float4(position, 1.0);
    float4x4 param_1 = g_ModelViewProjectionMatrix;
    out.gl_Position = mul(param, param_1);
    out.v_TexCoord = in.a_TexCoord;
    float2 param_2 = out.v_TexCoord;
    float2 _117 = applyFx(param_2, g_Direction, g_Offset, g_Scale);
    out.v_TexCoord = _117;
    return out;
}

