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

fragment main0_out main0(main0_in in [[stage_in]], constant float& g_NoiseAmount [[buffer(0)]], constant float& g_Threshold [[buffer(1)]], constant float& g_NoiseSmoothness [[buffer(2)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture2 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture2Smplr [[sampler(1)]])
{
    main0_out out = {};
    float mask = 1.0;
    float4 sampleValue = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float noiseSample = g_Texture2.sample(g_Texture2Smplr, in.v_NoiseTexCoord.xy).x * g_Texture2.sample(g_Texture2Smplr, in.v_NoiseTexCoord.zw).x;
    noiseSample = mix(sampleValue.w, sampleValue.w * noiseSample, g_NoiseAmount);
    float _52 = sampleValue.w;
    float4 _54 = sampleValue;
    float3 _56 = _54.xyz * _52;
    sampleValue.x = _56.x;
    sampleValue.y = _56.y;
    sampleValue.z = _56.z;
    sampleValue.w = 1.0;
    out.out_FragColor = (sampleValue * mask) * step(g_Threshold, dot(float3(0.10999999940395355224609375, 0.589999973773956298828125, 0.300000011920928955078125), sampleValue.xyz));
    out.out_FragColor.w *= smoothstep(0.5 - g_NoiseSmoothness, 0.5 + g_NoiseSmoothness, noiseSample);
    return out;
}

