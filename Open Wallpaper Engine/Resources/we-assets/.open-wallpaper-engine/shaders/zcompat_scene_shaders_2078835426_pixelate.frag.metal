#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 out_FragColor [[color(0)]];
};

struct main0_in
{
    float2 v_PixelCoord [[user(locn0)]];
    float4 v_PixelSize [[user(locn1)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant float4& g_Texture0Resolution [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float2 texCoord00 = round(in.v_PixelCoord) * in.v_PixelSize.xy;
    texCoord00 = (round(texCoord00 * g_Texture0Resolution.xy) * in.v_PixelSize.zw) + (in.v_PixelSize.zw * 0.5);
    float4 finalColor = g_Texture0.sample(g_Texture0Smplr, texCoord00);
    out.out_FragColor = finalColor;
    return out;
}

