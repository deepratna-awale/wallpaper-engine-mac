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
};

static inline __attribute__((always_inline))
float3 _pow(thread const float3& value, thread const float& exponent)
{
    return powr(value, float3(exponent));
}

static inline __attribute__((always_inline))
float3 srgb(thread const float3& v)
{
    float3 c = step(float3(0.040449999272823333740234375), v);
    float3 param = (v + float3(0.054999999701976776123046875)) / float3(1.05499994754791259765625);
    float param_1 = 2.400000095367431640625;
    return (c * _pow(param, param_1)) + ((float3(1.0) - c) * (v / float3(12.9200000762939453125)));
}

fragment main0_out main0(main0_in in [[stage_in]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float3 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord).xyz;
    float3 param = fast::clamp(albedo, float3(0.0), float3(1.0));
    out.out_FragColor = float4(srgb(param), 1.0);
    return out;
}

