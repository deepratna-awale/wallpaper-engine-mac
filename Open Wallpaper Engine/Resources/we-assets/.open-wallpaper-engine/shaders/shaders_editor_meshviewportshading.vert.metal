#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 v_ScreenPos [[user(locn0)]];
    float4 v_ScreenNorm [[user(locn1)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float4 a_Color [[attribute(1)]];
};

static inline __attribute__((always_inline))
float4 mul(thread const float4& value, thread const float4x4& matrix)
{
    return matrix * value;
}

vertex main0_out main0(main0_in in [[stage_in]], constant float4x4& g_ModelViewProjectionMatrix [[buffer(0)]])
{
    main0_out out = {};
    float4 param = float4(in.a_Position, 1.0);
    float4x4 param_1 = g_ModelViewProjectionMatrix;
    out.gl_Position = mul(param, param_1);
    float3 normal = fast::normalize((in.a_Color.xyz * 2.0) - float3(1.0));
    out.v_ScreenPos = out.gl_Position;
    float4 param_2 = float4(normal, 0.0);
    float4x4 param_3 = g_ModelViewProjectionMatrix;
    out.v_ScreenNorm = mul(param_2, param_3);
    return out;
}

