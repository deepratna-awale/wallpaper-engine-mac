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
float3 blur3(thread const float2& u, thread const float2& d, texture2d<float> g_Texture0, sampler g_Texture0Smplr)
{
    return ((g_Texture0.sample(g_Texture0Smplr, (u + d)).xyz * 0.25) + (g_Texture0.sample(g_Texture0Smplr, u).xyz * 0.5)) + (g_Texture0.sample(g_Texture0Smplr, (u - d)).xyz * 0.25);
}

fragment main0_out main0(main0_in in [[stage_in]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float2 param = in.v_TexCoord.xy;
    float2 param_1 = float2(in.v_TexCoord.z, 0.0);
    float3 albedo = blur3(param, param_1, g_Texture0, g_Texture0Smplr);
    out.out_FragColor = float4(albedo, 1.0);
    return out;
}

