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

fragment main0_out main0(main0_in in [[stage_in]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture2 [[texture(1)]], texture2d<float> g_Texture1 [[texture(2)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture2Smplr [[sampler(1)]], sampler g_Texture1Smplr [[sampler(2)]])
{
    main0_out out = {};
    float2 blurredCoords = in.v_TexCoord.xy;
    float4 blurred = g_Texture0.sample(g_Texture0Smplr, blurredCoords);
    float4 albedoOld = g_Texture2.sample(g_Texture2Smplr, in.v_TexCoord.xy);
    float mask = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.zw).x;
    blurred = mix(albedoOld, blurred, float4(mask));
    out.out_FragColor = blurred;
    return out;
}

