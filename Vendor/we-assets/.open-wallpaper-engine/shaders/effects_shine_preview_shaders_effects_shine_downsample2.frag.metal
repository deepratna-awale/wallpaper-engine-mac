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
    float4 v_NoiseTexCoord [[user(locn1)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant float& g_NoiseAmount [[buffer(0)]], constant float& g_Threshold [[buffer(1)]], texture2d<float> g_Texture1 [[texture(0)]], texture2d<float> g_Texture0 [[texture(1)]], texture2d<float> g_Texture2 [[texture(2)]], sampler g_Texture1Smplr [[sampler(0)]], sampler g_Texture0Smplr [[sampler(1)]], sampler g_Texture2Smplr [[sampler(2)]])
{
    main0_out out = {};
    float mask = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.zw).x;
    float4 sampleValue = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float noiseSample = g_Texture2.sample(g_Texture2Smplr, in.v_NoiseTexCoord.xy).x * g_Texture2.sample(g_Texture2Smplr, in.v_NoiseTexCoord.zw).x;
    noiseSample = mix(sampleValue.w, sampleValue.w * noiseSample, g_NoiseAmount);
    float _57 = sampleValue.w;
    float4 _59 = sampleValue;
    float3 _61 = _59.xyz * _57;
    sampleValue.x = _61.x;
    sampleValue.y = _61.y;
    sampleValue.z = _61.z;
    sampleValue.w = 1.0;
    out.out_FragColor = (sampleValue * mask) * step(g_Threshold, dot(float3(0.10999999940395355224609375, 0.589999973773956298828125, 0.300000011920928955078125), sampleValue.xyz));
    out.out_FragColor.w *= noiseSample;
    return out;
}

