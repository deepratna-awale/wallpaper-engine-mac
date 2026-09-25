#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 out_FragColor [[color(0)]];
};

struct main0_in
{
    float3 g_ScreenPosition [[user(locn0)]];
};

fragment main0_out main0(main0_in in [[stage_in]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float2 texCoords = in.g_ScreenPosition.xy / float2(in.g_ScreenPosition.z);
    texCoords = (texCoords * float2(0.5, -0.5)) + float2(0.5);
    float4 sampleValue = g_Texture0.sample(g_Texture0Smplr, texCoords);
    float lightness = dot(sampleValue.xyz, float3(0.300000011920928955078125, 0.589999973773956298828125, 0.10999999940395355224609375));
    float color = step(lightness, 0.5);
    out.out_FragColor = float4(float3(1.0) * color, 1.0);
    return out;
}

