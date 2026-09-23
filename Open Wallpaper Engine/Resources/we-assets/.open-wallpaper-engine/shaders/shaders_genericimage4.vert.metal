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

vertex main0_out main0(main0_in in [[stage_in]], constant float4x4& g_ModelMatrix [[buffer(0)]], constant float3& g_EyePosition [[buffer(1)]], constant float4x4& g_ModelViewProjectionMatrix [[buffer(2)]])
{
    main0_out out = {};
    float3 position = in.a_Position;
    float3 localPos = position;
    out.v_TexCoord = in.a_TexCoord;
    float4 param = float4(localPos, 1.0);
    float4x4 param_1 = g_ModelMatrix;
    float4 worldPos = mul(param, param_1);
    float3 viewDir = g_EyePosition - worldPos.xyz;
    float4 param_2 = float4(localPos, 1.0);
    float4x4 param_3 = g_ModelViewProjectionMatrix;
    out.gl_Position = mul(param_2, param_3);
    return out;
}

