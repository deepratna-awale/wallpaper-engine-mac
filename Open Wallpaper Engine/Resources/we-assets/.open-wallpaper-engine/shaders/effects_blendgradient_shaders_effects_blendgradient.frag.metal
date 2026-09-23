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
float GetUVBlend(thread const float2& uv)
{
    return 1.0;
}

static inline __attribute__((always_inline))
float3 ApplyBlending(thread const int& mode, thread const float3& base, thread const float3& blend, thread const float& amount)
{
    return mix(base, blend, float3(fast::clamp(amount, 0.0, 1.0)));
}

static inline __attribute__((always_inline))
float4 PerformBlend(thread float4& albedo, thread const float4& blendColors, thread float& blendAlpha)
{
    blendAlpha *= blendColors.w;
    int param = 0;
    float3 param_1 = albedo.xyz;
    float3 param_2 = blendColors.xyz;
    float param_3 = blendAlpha;
    float3 _59 = ApplyBlending(param, param_1, param_2, param_3);
    albedo.x = _59.x;
    albedo.y = _59.y;
    albedo.z = _59.z;
    return albedo;
}

fragment main0_out main0(main0_in in [[stage_in]], constant float& g_GradientScale [[buffer(0)]], constant float& g_Multiply [[buffer(1)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], texture2d<float> g_Texture2 [[texture(2)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]], sampler g_Texture2Smplr [[sampler(2)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float2 blendUV = in.v_TexCoord.zw;
    float4 blendColors = g_Texture1.sample(g_Texture1Smplr, blendUV);
    float blend = 1.0;
    float gradient = g_Texture2.sample(g_Texture2Smplr, blendUV).x;
    blend = smoothstep(fast::clamp(gradient - g_GradientScale, 0.0, 1.0), fast::clamp(gradient + g_GradientScale, 0.0, 1.0), g_Multiply);
    float2 param = blendUV;
    float blendAlpha = GetUVBlend(param) * blend;
    float4 param_1 = albedo;
    float4 param_2 = blendColors;
    float param_3 = blendAlpha;
    float4 _125 = PerformBlend(param_1, param_2, param_3);
    albedo = _125;
    out.out_FragColor = albedo;
    return out;
}

