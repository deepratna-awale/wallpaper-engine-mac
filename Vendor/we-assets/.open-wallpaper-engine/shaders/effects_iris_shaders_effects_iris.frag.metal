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
    float2 v_TexCoordIris [[user(locn1)]];
};

fragment main0_out main0(main0_in in [[stage_in]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float mask = 1.0;
    float4 iris = g_Texture0.sample(g_Texture0Smplr, (in.v_TexCoord.xy + in.v_TexCoordIris));
    albedo = iris;
    out.out_FragColor = albedo;
    return out;
}

