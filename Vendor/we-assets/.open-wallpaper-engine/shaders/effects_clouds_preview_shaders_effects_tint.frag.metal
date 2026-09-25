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
};

static inline __attribute__((always_inline))
float3 ApplyBlending(thread const int& mode, thread const float3& base, thread const float3& blend, thread const float& amount)
{
    return mix(base, blend, float3(fast::clamp(amount, 0.0, 1.0)));
}

fragment main0_out main0(main0_in in [[stage_in]], constant float& g_BlendAlpha [[buffer(0)]], constant float3& g_TintColor [[buffer(1)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float mask = g_BlendAlpha;
    int param = 2;
    float3 param_1 = albedo.xyz;
    float3 param_2 = g_TintColor;
    float param_3 = mask;
    float3 _58 = ApplyBlending(param, param_1, param_2, param_3);
    albedo.x = _58.x;
    albedo.y = _58.y;
    albedo.z = _58.z;
    out.out_FragColor = albedo;
    return out;
}

