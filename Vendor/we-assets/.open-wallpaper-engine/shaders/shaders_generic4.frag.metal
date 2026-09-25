#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 out_FragColor [[color(0)]];
};

struct main0_in
{
    float3 v_WorldNormal [[user(locn0)]];
    float3 v_WorldPos [[user(locn1)]];
    float2 v_TexCoord [[user(locn2)]];
    float4 v_ViewDir [[user(locn3)]];
    float3 v_LightAmbientColor [[user(locn4)]];
};

static inline __attribute__((always_inline))
float3 PerformLighting_V1(thread const float3& worldPosition, thread const float3& color, thread const float3& normal, thread const float3& viewDirection, thread const float3& specularTint, thread const float3& ambient, thread const float& roughness, thread const float& metallic)
{
    float diffuse = fast::max(dot(fast::normalize(normal), fast::normalize(viewDirection)), 0.0);
    return (color * (ambient + float3(diffuse))) + ((specularTint * metallic) * (1.0 - roughness));
}

static inline __attribute__((always_inline))
float3 CombineLighting(thread const float3& light, thread const float3& ambient)
{
    return ambient + light;
}

fragment main0_out main0(main0_in in [[stage_in]], constant float3& g_TintColor [[buffer(0)]], constant float& g_TintAlpha [[buffer(1)]], constant float& g_Metallic [[buffer(2)]], constant float& g_Roughness [[buffer(3)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float4 _71 = albedo;
    float3 _73 = _71.xyz * g_TintColor;
    albedo.x = _73.x;
    albedo.y = _73.y;
    albedo.z = _73.z;
    albedo.w *= g_TintAlpha;
    float metallic = g_Metallic;
    float roughness = g_Roughness;
    float3 f0 = float3(0.039999999105930328369140625);
    f0 = mix(f0, albedo.xyz, float3(metallic));
    float viewDist = length(in.v_ViewDir.xyz);
    float3 normalizedViewVector = in.v_ViewDir.xyz / float3(viewDist);
    float3 normal = fast::normalize(in.v_WorldNormal);
    float3 light = float3(0.0);
    float3 param = in.v_WorldPos;
    float3 param_1 = albedo.xyz;
    float3 param_2 = normal;
    float3 param_3 = normalizedViewVector;
    float3 param_4 = float3(1.0);
    float3 param_5 = f0;
    float param_6 = roughness;
    float param_7 = metallic;
    light = PerformLighting_V1(param, param_1, param_2, param_3, param_4, param_5, param_6, param_7);
    float3 ambient = in.v_LightAmbientColor * albedo.xyz;
    float3 param_8 = light;
    float3 param_9 = ambient;
    float3 _155 = CombineLighting(param_8, param_9);
    albedo.x = _155.x;
    albedo.y = _155.y;
    albedo.z = _155.z;
    out.out_FragColor = albedo;
    return out;
}

