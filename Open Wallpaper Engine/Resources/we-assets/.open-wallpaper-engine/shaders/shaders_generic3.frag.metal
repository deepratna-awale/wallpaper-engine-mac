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
    float2 v_TexCoord [[user(locn0)]];
    float4 v_ViewDir [[user(locn1)]];
};

static inline __attribute__((always_inline))
float3 CombineLighting(thread const float3& light, thread const float3& ambient)
{
    return ambient + light;
}

fragment main0_out main0(main0_in in [[stage_in]], constant float3& g_TintColor [[buffer(0)]], constant float& g_TintAlpha [[buffer(1)]], constant float& g_Metallic [[buffer(2)]], constant float& g_Roughness [[buffer(3)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float4 _35 = albedo;
    float3 _37 = _35.xyz * g_TintColor;
    albedo.x = _37.x;
    albedo.y = _37.y;
    albedo.z = _37.z;
    albedo.w *= g_TintAlpha;
    float metallic = g_Metallic;
    float roughness = g_Roughness;
    float3 f0 = float3(0.039999999105930328369140625);
    f0 = mix(f0, albedo.xyz, float3(metallic));
    float viewDist = length(in.v_ViewDir.xyz);
    float3 normalizedViewVector = in.v_ViewDir.xyz / float3(viewDist);
    float3 light = float3(0.0);
    float3 ambient = albedo.xyz;
    float3 param = light;
    float3 param_1 = ambient;
    float3 _94 = CombineLighting(param, param_1);
    albedo.x = _94.x;
    albedo.y = _94.y;
    albedo.z = _94.z;
    out.out_FragColor = albedo;
    return out;
}

