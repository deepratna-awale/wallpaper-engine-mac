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
};

fragment main0_out main0(main0_in in [[stage_in]], constant float& g_Threshold [[buffer(0)]], texture2d<float> g_Texture1 [[texture(0)]], texture2d<float> g_Texture0 [[texture(1)]], sampler g_Texture1Smplr [[sampler(0)]], sampler g_Texture0Smplr [[sampler(1)]])
{
    main0_out out = {};
    float mask = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.zw).x;
    float4 sampleValue = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float _33 = sampleValue.w;
    float4 _35 = sampleValue;
    float3 _37 = _35.xyz * _33;
    sampleValue.x = _37.x;
    sampleValue.y = _37.y;
    sampleValue.z = _37.z;
    sampleValue.w = 1.0;
    out.out_FragColor = (sampleValue * mask) * step(g_Threshold, dot(float3(0.10999999940395355224609375, 0.589999973773956298828125, 0.300000011920928955078125), sampleValue.xyz));
    return out;
}

