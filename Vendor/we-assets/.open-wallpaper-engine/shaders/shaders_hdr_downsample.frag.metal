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

fragment main0_out main0(main0_in in [[stage_in]], constant float4& g_RenderVar0 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float3 albedo = ((g_Texture0.sample(g_Texture0Smplr, (in.v_TexCoord + g_RenderVar0.xy)).xyz + g_Texture0.sample(g_Texture0Smplr, (in.v_TexCoord + g_RenderVar0.zy)).xyz) + g_Texture0.sample(g_Texture0Smplr, (in.v_TexCoord + g_RenderVar0.xw)).xyz) + g_Texture0.sample(g_Texture0Smplr, (in.v_TexCoord + g_RenderVar0.zw)).xyz;
    albedo *= 0.25;
    out.out_FragColor = float4(albedo, 1.0);
    return out;
}

