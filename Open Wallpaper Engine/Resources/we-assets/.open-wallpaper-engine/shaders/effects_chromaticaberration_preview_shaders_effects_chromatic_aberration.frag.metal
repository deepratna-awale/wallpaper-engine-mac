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

fragment main0_out main0(main0_in in [[stage_in]], constant float2& u_Center [[buffer(0)]], constant float& u_CenterFalloff [[buffer(1)]], constant float& u_Strength [[buffer(2)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float2 delta = in.v_TexCoord - u_Center;
    float falloff = mix(0.5 / (length(delta) + 9.9999997473787516355514526367188e-05), 1.0, u_CenterFalloff);
    delta *= ((u_Strength * 0.00999999977648258209228515625) * falloff);
    float2 coords0 = in.v_TexCoord + delta;
    float2 coords1 = in.v_TexCoord - delta;
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float4 s0 = g_Texture0.sample(g_Texture0Smplr, coords0);
    float4 s1 = g_Texture0.sample(g_Texture0Smplr, coords1);
    albedo.x = s0.x;
    albedo.z = s1.z;
    out.out_FragColor = albedo;
    return out;
}

