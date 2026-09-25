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
float3 _srgb(thread const float3& v)
{
    float3 param = v;
    float param_1 = 0.4166666567325592041015625;
    return fast::max((_pow(param, param_1) * 1.05499994754791259765625) - float3(0.054999999701976776123046875), float3(0.0));
}

fragment main0_out main0(main0_in in [[stage_in]], constant float2& g_HDRParams [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float3 param = albedo.xyz / float3(g_HDRParams.x);
    float3 _65 = _srgb(param);
    albedo.x = _65.x;
    albedo.y = _65.y;
    albedo.z = _65.z;
    out.out_FragColor = albedo;
    return out;
}

