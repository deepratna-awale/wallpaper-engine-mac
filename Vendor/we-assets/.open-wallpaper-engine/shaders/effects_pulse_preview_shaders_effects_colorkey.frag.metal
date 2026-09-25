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

fragment main0_out main0(main0_in in [[stage_in]], constant float3& g_KeyColor [[buffer(0)]], constant float& g_KeyFuzz [[buffer(1)]], constant float& g_KeyTolerance [[buffer(2)]], constant float& g_KeyAlpha [[buffer(3)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float delta = length(g_KeyColor - albedo.xyz);
    float blend = smoothstep(0.001000000047497451305389404296875, 0.00200000009499490261077880859375 + g_KeyFuzz, delta - g_KeyTolerance);
    albedo.w *= mix(g_KeyAlpha, 1.0, blend);
    out.out_FragColor = albedo;
    return out;
}

