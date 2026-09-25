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
    float2 v_NoiseCoord [[user(locn1)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant float& u_amount [[buffer(0)]], texture2d<float> g_Texture2 [[texture(0)]], texture2d<float> g_Texture0 [[texture(1)]], sampler g_Texture2Smplr [[sampler(0)]], sampler g_Texture0Smplr [[sampler(1)]])
{
    main0_out out = {};
    float mask = 1.0;
    float3 _noise = g_Texture2.sample(g_Texture2Smplr, in.v_NoiseCoord).xyz;
    float2 uvs = in.v_TexCoord.xy;
    float2 offset = float2((((_noise.x * 2.0) - 1.0) * u_amount) * mask, 0.0);
    uvs += offset;
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, uvs);
    out.out_FragColor = albedo;
    return out;
}

