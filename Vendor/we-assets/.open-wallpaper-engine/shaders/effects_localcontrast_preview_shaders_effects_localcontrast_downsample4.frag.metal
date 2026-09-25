#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 out_FragColor [[color(0)]];
};

struct main0_in
{
    float4 v_TexCoord01 [[user(locn0)]];
    float4 v_TexCoord23 [[user(locn1)]];
};

fragment main0_out main0(main0_in in [[stage_in]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    out.out_FragColor = (((g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord01.xy) + g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord01.zw)) + g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord23.xy)) + g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord23.zw)) * 0.25;
    return out;
}

