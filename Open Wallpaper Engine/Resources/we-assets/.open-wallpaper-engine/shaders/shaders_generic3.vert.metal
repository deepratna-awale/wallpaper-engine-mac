#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 v_ViewDir [[user(locn0)]];
    float2 v_TexCoord [[user(locn1)]];
    float3 v_LightAmbientColor [[user(locn2)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float3 a_Normal [[attribute(1)]];
    float2 a_TexCoord [[attribute(2)]];
};

static inline __attribute__((always_inline))
float4 mul(thread const float4& value, thread const float4x4& matrix)
{
    return matrix * value;
}

static inline __attribute__((always_inline))
float3 mul(thread const float3& value, thread const float3x3& matrix)
{
    return matrix * value;
}

vertex main0_out main0(main0_in in [[stage_in]], constant float4x4& g_ModelMatrix [[buffer(0)]], constant float4x4& g_ViewProjectionMatrix [[buffer(1)]], constant float3& g_EyePosition [[buffer(2)]], constant float3& g_LightSkylightColor [[buffer(3)]], constant float3& g_LightAmbientColor [[buffer(4)]])
{
    main0_out out = {};
    float3 localPos = in.a_Position;
    float3 localNormal = in.a_Normal;
    float4 param = float4(localPos, 1.0);
    float4x4 param_1 = g_ModelMatrix;
    float4 worldPos = mul(param, param_1);
    float4 param_2 = worldPos;
    float4x4 param_3 = g_ViewProjectionMatrix;
    out.gl_Position = mul(param_2, param_3);
    float3 param_4 = localNormal;
    float3x3 param_5 = float3x3(g_ModelMatrix[0].xyz, g_ModelMatrix[1].xyz, g_ModelMatrix[2].xyz);
    float3 normal = fast::normalize(mul(param_4, param_5));
    out.v_TexCoord = in.a_TexCoord;
    float3 _97 = g_EyePosition - worldPos.xyz;
    out.v_ViewDir.x = _97.x;
    out.v_ViewDir.y = _97.y;
    out.v_ViewDir.z = _97.z;
    out.v_ViewDir.w = worldPos.y;
    out.v_LightAmbientColor = mix(g_LightSkylightColor, g_LightAmbientColor, float3((dot(normal, float3(0.0, 1.0, 0.0)) * 0.5) + 0.5));
    return out;
}

