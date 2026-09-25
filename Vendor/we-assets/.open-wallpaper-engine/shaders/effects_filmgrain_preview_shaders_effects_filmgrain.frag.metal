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
float3 _pow(thread const float3& value, thread const float& exponent)
{
    return powr(value, float3(exponent));
}

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    float _49;
    if (B.x < 0.5)
    {
        _49 = ((2.0 * A.x) * B.x) + ((A.x * A.x) * (1.0 - (2.0 * B.x)));
    }
    else
    {
        _49 = (sqrt(A.x) * ((2.0 * B.x) - 1.0)) + ((2.0 * A.x) * (1.0 - B.x));
    }
    float _93;
    if (B.y < 0.5)
    {
        _93 = ((2.0 * A.y) * B.y) + ((A.y * A.y) * (1.0 - (2.0 * B.y)));
    }
    else
    {
        _93 = (sqrt(A.y) * ((2.0 * B.y) - 1.0)) + ((2.0 * A.y) * (1.0 - B.y));
    }
    float _135;
    if (B.z < 0.5)
    {
        _135 = ((2.0 * A.z) * B.z) + ((A.z * A.z) * (1.0 - (2.0 * B.z)));
    }
    else
    {
        _135 = (sqrt(A.z) * ((2.0 * B.z) - 1.0)) + ((2.0 * A.z) * (1.0 - B.z));
    }
    return mix(A, float3(_49, _93, _135), float3(opacity));
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
    float3 param_2 = _noise;
    float param_3 = g_NoisePower;
    _noise = _pow(param_2, param_3);
    float blend = g_NoiseAlpha;
    float3 param_4 = albedo.xyz;
    float3 param_5 = _noise;
    float param_6 = blend;
    float3 _246 = ApplyBlending(12, param_4, param_5, param_6);
    albedo.x = _246.x;
    albedo.y = _246.y;
    albedo.z = _246.z;
    out.out_FragColor = albedo;
    return out;
}

