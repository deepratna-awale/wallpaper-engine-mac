#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 v_WorldNormal [[user(locn0)]];
    float4 v_ViewDir [[user(locn1)]];
    float2 v_TexCoord [[user(locn2)]];
    float3 v_LightAmbientColor [[user(locn3)]];
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

static inline __attribute__((always_inline))
void ApplyPositionNormal(thread const float3& position, thread const float3& normal, thread float4& worldPosition, thread float3& worldNormal, constant float4x4& g_ModelMatrix, constant float3x3& g_NormalModelMatrix)
{
    float4 param = float4(position, 1.0);
    float4x4 param_1 = g_ModelMatrix;
    worldPosition = mul(param, param_1);
    float3 param_2 = normal;
    float3x3 param_3 = g_NormalModelMatrix;
    worldNormal = mul(param_2, param_3);
}

static inline __attribute__((always_inline))
float3 ApplyAmbientLighting(thread const float3& normal, constant float3& g_LightSkylightColor, constant float3& g_LightAmbientColor)
{
    return mix(g_LightSkylightColor, g_LightAmbientColor, float3((dot(normal, float3(0.0, 1.0, 0.0)) * 0.5) + 0.5));
}

vertex main0_out main0(main0_in in [[stage_in]], constant float4x4& g_ModelMatrix [[buffer(0)]], constant float3x3& g_NormalModelMatrix [[buffer(1)]], constant float3& g_LightSkylightColor [[buffer(2)]], constant float3& g_LightAmbientColor [[buffer(3)]], constant float& g_FurDistance [[buffer(4)]], constant float4x4& g_ViewProjectionMatrix [[buffer(5)]], constant float3& g_EyePosition [[buffer(6)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]], uint gl_InstanceID [[instance_id]])
{
    main0_out out = {};
    float3 localPos = in.a_Position;
    float3 localNormal = in.a_Normal;
    float3 param = localPos;
    float3 param_1 = localNormal;
    float4 param_2;
    float3 param_3;
    ApplyPositionNormal(param, param_1, param_2, param_3, g_ModelMatrix, g_NormalModelMatrix);
    float4 worldPos = param_2;
    float3 worldNormal = param_3;
    float furDistance = g_Texture0.sample(g_Texture0Smplr, in.a_TexCoord, level(0.0)).w;
    out.v_WorldNormal.w = float(gl_InstanceID) / 1.0;
    float4 _134 = worldPos;
    float3 _136 = _134.xyz + (((worldNormal * out.v_WorldNormal.w) * g_FurDistance) * furDistance);
    worldPos.x = _136.x;
    worldPos.y = _136.y;
    worldPos.z = _136.z;
    float4 param_4 = worldPos;
    float4x4 param_5 = g_ViewProjectionMatrix;
    out.gl_Position = mul(param_4, param_5);
    out.v_TexCoord = in.a_TexCoord;
    float3 _166 = g_EyePosition - worldPos.xyz;
    out.v_ViewDir.x = _166.x;
    out.v_ViewDir.y = _166.y;
    out.v_ViewDir.z = _166.z;
    out.v_ViewDir.w = worldPos.y;
    out.v_WorldNormal.x = worldNormal.x;
    out.v_WorldNormal.y = worldNormal.y;
    out.v_WorldNormal.z = worldNormal.z;
    float3 param_6 = worldNormal;
    out.v_LightAmbientColor = ApplyAmbientLighting(param_6, g_LightSkylightColor, g_LightAmbientColor);
    return out;
}

