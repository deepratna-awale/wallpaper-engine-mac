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
float2 ApplyCompositeOffset(thread const float2& texCoords, thread const float2& textureResolution)
{
    return texCoords;
}

static inline __attribute__((always_inline))
float4 ApplyComposite(thread const float4& original, thread float4& effect, constant float3& g_CompositeColor)
{
    float4 _28 = effect;
    float3 _30 = _28.xyz * g_CompositeColor;
    effect.x = _30.x;
    effect.y = _30.y;
    effect.z = _30.z;
    return effect;
}

fragment main0_out main0(main0_in in [[stage_in]], constant float3& g_CompositeColor [[buffer(0)]], constant float4& g_Texture0Resolution [[buffer(1)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture2 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture2Smplr [[sampler(1)]])
{
    main0_out out = {};
    float2 blurredCoords = in.v_TexCoord.xy;
    float2 param = blurredCoords;
    float2 param_1 = g_Texture0Resolution.xy;
    float4 blurred = g_Texture0.sample(g_Texture0Smplr, ApplyCompositeOffset(param, param_1));
    float4 albedoOld = g_Texture2.sample(g_Texture2Smplr, in.v_TexCoord.xy);
    float mask = 1.0;
    float div = mix(blurred.w, 1.0, step(blurred.w, 0.0));
    float4 param_2 = albedoOld;
    float4 param_3 = float4(blurred.xyz / float3(div), blurred.w);
    float4 _98 = ApplyComposite(param_2, param_3, g_CompositeColor);
    blurred = _98;
    blurred = mix(albedoOld, blurred, float4(mask));
    blurred.w = albedoOld.w;
    out.out_FragColor = blurred;
    return out;
}

