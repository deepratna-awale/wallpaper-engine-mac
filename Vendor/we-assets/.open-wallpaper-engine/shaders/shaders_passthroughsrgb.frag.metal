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
float3 lin(thread const float3& v)
{
    float3 c = step(float3(0.040449999272823333740234375), v);
    return (c * powr((v + float3(0.054999999701976776123046875)) / float3(1.05499994754791259765625), float3(2.400000095367431640625))) + ((float3(1.0) - c) * (v / float3(12.9200000762939453125)));
}

fragment main0_out main0(main0_in in [[stage_in]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float3 param = albedo.xyz;
    float3 _58 = lin(param);
    albedo.x = _58.x;
    albedo.y = _58.y;
    albedo.z = _58.z;
    out.out_FragColor = albedo;
    return out;
}

