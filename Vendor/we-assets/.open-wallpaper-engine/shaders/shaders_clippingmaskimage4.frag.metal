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

fragment main0_out main0(main0_in in [[stage_in]], constant float4& g_RenderVar0 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float albedoAlpha = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord).w;
    float mask = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord).x;
    float4 color = float4(mask, 0.0, 0.0, mix(powr(albedoAlpha, 4.0), albedoAlpha, mask));
    color.x *= color.w;
    color.x = mix(color.x, 1.0 - color.x, g_RenderVar0.x);
    out.out_FragColor = color;
    return out;
}

