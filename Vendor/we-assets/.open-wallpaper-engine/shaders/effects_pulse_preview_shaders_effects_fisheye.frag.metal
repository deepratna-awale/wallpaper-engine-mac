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

fragment main0_out main0(main0_in in [[stage_in]], constant float2& g_Center [[buffer(0)]], constant float& g_Size [[buffer(1)]], constant float& g_Scale [[buffer(2)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float aperture = 178.0;
    float apertureHalf = (0.5 * aperture) * 0.01745327748358249664306640625;
    float maxFactor = sin(apertureHalf);
    float2 xy = ((in.v_TexCoord - g_Center) * 2.0) / float2(g_Size);
    float d = length(xy);
    float alpha = 1.0;
    float2 uv;
    if (d < (2.0 - maxFactor))
    {
        d = length(xy * maxFactor);
        float z = sqrt(1.0 - (d * d));
        float r = precise::atan2(d, z) / 3.141590118408203125;
        float phi = precise::atan2(xy.y, xy.x);
        uv.x = ((r * cos(phi)) * g_Size) + g_Center.x;
        uv.y = ((r * sin(phi)) * g_Size) + g_Center.y;
    }
    else
    {
        uv = in.v_TexCoord;
    }
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, mix(in.v_TexCoord, uv, float2(g_Scale)));
    albedo.w *= alpha;
    out.out_FragColor = albedo;
    return out;
}

