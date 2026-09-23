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

fragment main0_out main0(main0_in in [[stage_in]], constant float2& g_ParallaxPosition [[buffer(0)]], constant float2& g_Scale [[buffer(1)]], texture2d<float> g_Texture1 [[texture(0)]], texture2d<float> g_Texture0 [[texture(1)]], sampler g_Texture1Smplr [[sampler(0)]], sampler g_Texture0Smplr [[sampler(1)]])
{
    main0_out out = {};
    float depth = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.zw).x;
    float mask = 1.0;
    float2 pointer = float2(in.v_TexCoord.z, 1.0 - in.v_TexCoord.w);
    pointer = (((pointer - g_ParallaxPosition) * float2(2.0, -2.0)) * g_Scale) * (-0.039999999105930328369140625);
    float2 offset = (pointer * ((depth * 2.0) - 1.0)) * mask;
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, (in.v_TexCoord.xy + offset));
    out.out_FragColor = albedo;
    return out;
}

