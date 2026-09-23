#pragma clang diagnostic ignored "-Wmissing-prototypes"

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
    float4 v_TexCoordNoise [[user(locn1)]];
};

static inline __attribute__((always_inline))
float greyscale(thread const float3& color)
{
    return dot(color, float3(0.10999999940395355224609375, 0.589999973773956298828125, 0.300000011920928955078125));
}

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    float _38;
    if (B.x < 0.5)
    {
        _38 = ((2.0 * A.x) * B.x) + ((A.x * A.x) * (1.0 - (2.0 * B.x)));
    }
    else
    {
        _38 = (sqrt(A.x) * ((2.0 * B.x) - 1.0)) + ((2.0 * A.x) * (1.0 - B.x));
    }
    float _82;
    if (B.y < 0.5)
    {
        _82 = ((2.0 * A.y) * B.y) + ((A.y * A.y) * (1.0 - (2.0 * B.y)));
    }
    else
    {
        _82 = (sqrt(A.y) * ((2.0 * B.y) - 1.0)) + ((2.0 * A.y) * (1.0 - B.y));
    }
    float _124;
    if (B.z < 0.5)
    {
        _124 = ((2.0 * A.z) * B.z) + ((A.z * A.z) * (1.0 - (2.0 * B.z)));
    }
    else
    {
        _124 = (sqrt(A.z) * ((2.0 * B.z) - 1.0)) + ((2.0 * A.z) * (1.0 - B.z));
    }
    return mix(A, float3(_38, _82, _124), float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant float& g_NoisePower [[buffer(0)]], constant float& g_NoiseAlpha [[buffer(1)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float3 _noise = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoordNoise.xy).xyz;
    float3 _noise2 = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoordNoise.zw).yzx;
    float3 param = _noise;
    _noise = float3(greyscale(param));
    float3 param_1 = _noise2;
    _noise2 = float3(greyscale(param_1));
    _noise = fast::clamp(_noise * _noise2, float3(0.0), float3(1.0));
    _noise = powr(_noise, float3(g_NoisePower));
    float blend = g_NoiseAlpha;
    float3 param_2 = albedo.xyz;
    float3 param_3 = _noise;
    float param_4 = blend;
    float3 _234 = ApplyBlending(12, param_2, param_3, param_4);
    albedo.x = _234.x;
    albedo.y = _234.y;
    albedo.z = _234.z;
    out.out_FragColor = albedo;
    return out;
}

