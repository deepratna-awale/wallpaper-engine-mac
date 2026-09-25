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

fragment main0_out main0(main0_in in [[stage_in]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float3 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord).xyz;
    float3 bloom = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord).xyz;
    albedo += bloom;
    out.out_FragColor = float4(albedo, 1.0);
    return out;
}

