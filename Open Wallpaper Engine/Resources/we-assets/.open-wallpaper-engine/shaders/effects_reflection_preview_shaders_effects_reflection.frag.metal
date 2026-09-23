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
    float2 v_ReflectedCoord [[user(locn1)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant float& g_Additive [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float4 reflected = g_Texture0.sample(g_Texture0Smplr, in.v_ReflectedCoord);
    float mask = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.zw).x;
    out.out_FragColor = mix(mix(albedo, reflected, float4(mask)), albedo + (reflected * mask), float4(g_Additive));
    return out;
}

