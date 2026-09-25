#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 v_ScreenPos [[user(locn0)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
};

static inline __attribute__((always_inline))
float4 mul(thread const float4& value, thread const float4x4& matrix)
{
    return matrix * value;
}

vertex main0_out main0(main0_in in [[stage_in]], constant float4x4& g_AltViewProjectionMatrix [[buffer(0)]], constant float4x4& g_ViewProjectionMatrix [[buffer(1)]])
{
    main0_out out = {};
    float4 param = float4(in.a_Position * float3(0.9900000095367431640625, 0.9900000095367431640625, 1.0), 1.0);
    float4x4 param_1 = g_AltViewProjectionMatrix;
    float4 param_2 = mul(param, param_1);
    float4x4 param_3 = g_ViewProjectionMatrix;
    out.gl_Position = mul(param_2, param_3);
    out.v_ScreenPos = out.gl_Position;
    return out;
}

