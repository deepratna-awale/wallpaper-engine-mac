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
    float4 v_TexCoord [[user(locn0)]];
    float4 v_TexCoordClouds [[user(locn1)]];
};

static inline __attribute__((always_inline))
float3 ApplyBlending(thread const int& mode, thread const float3& base, thread const float3& blend, thread const float& amount)
{
    return mix(base, blend, float3(fast::clamp(amount, 0.0, 1.0)));
}

fragment main0_out main0(main0_in in [[stage_in]], constant float& g_CloudLOD [[buffer(0)]], constant float& g_CloudThreshold [[buffer(1)]], constant float& g_CloudFeather [[buffer(2)]], constant float& g_CloudsAlpha [[buffer(3)]], constant float3& g_Color2 [[buffer(4)]], constant float3& g_Color1 [[buffer(5)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float4 cloudTexCoods = in.v_TexCoordClouds;
    float cloud0 = g_Texture1.sample(g_Texture1Smplr, cloudTexCoods.xy, level(g_CloudLOD)).x;
    float cloud1 = g_Texture1.sample(g_Texture1Smplr, cloudTexCoods.zw, level(g_CloudLOD)).x;
    float cloudBlend = cloud0 * cloud1;
    float3 cloudColor = float3(1.0);
    cloudBlend = smoothstep(g_CloudThreshold, g_CloudThreshold + g_CloudFeather, cloudBlend);
    float blend = cloudBlend * g_CloudsAlpha;
    cloudColor = (mix(g_Color2, g_Color1, float3(blend)) * cloud0) * cloud1;
    int param = 0;
    float3 param_1 = albedo.xyz;
    float3 param_2 = cloudColor;
    float param_3 = blend;
    float3 _105 = ApplyBlending(param, param_1, param_2, param_3);
    albedo.x = _105.x;
    albedo.y = _105.y;
    albedo.z = _105.z;
    out.out_FragColor = albedo;
    return out;
}

