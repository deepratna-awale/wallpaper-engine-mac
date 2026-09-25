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
    float4 v_TexCoordGlitch [[user(locn1)]];
    float4 v_TexCoordNoise [[user(locn2)]];
    float4 v_TexCoordVHSNoise [[user(locn3)]];
};

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    float _26;
    if (B.x < 0.5)
    {
        _26 = ((2.0 * A.x) * B.x) + ((A.x * A.x) * (1.0 - (2.0 * B.x)));
    }
    else
    {
        _26 = (sqrt(A.x) * ((2.0 * B.x) - 1.0)) + ((2.0 * A.x) * (1.0 - B.x));
    }
    float _70;
    if (B.y < 0.5)
    {
        _70 = ((2.0 * A.y) * B.y) + ((A.y * A.y) * (1.0 - (2.0 * B.y)));
    }
    else
    {
        _70 = (sqrt(A.y) * ((2.0 * B.y) - 1.0)) + ((2.0 * A.y) * (1.0 - B.y));
    }
    float _112;
    if (B.z < 0.5)
    {
        _112 = ((2.0 * A.z) * B.z) + ((A.z * A.z) * (1.0 - (2.0 * B.z)));
    }
    else
    {
        _112 = (sqrt(A.z) * ((2.0 * B.z) - 1.0)) + ((2.0 * A.z) * (1.0 - B.z));
    }
    return mix(A, float3(_26, _70, _112), float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant float& g_Time [[buffer(0)]], constant float& g_DistortionStrength [[buffer(1)]], constant float& g_DistortionWidth [[buffer(2)]], constant float& g_DistortionSpeed [[buffer(3)]], constant float& g_NoiseAlpha [[buffer(4)]], constant float& g_ArtifactsScale [[buffer(5)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float dblend = sin(g_Time);
    dblend = sign(dblend) * powr(abs(fast::max(9.9999997473787516355514526367188e-06, dblend)), 4.0);
    float2 distortion = float2(((dblend * g_DistortionStrength) * 0.0199999995529651641845703125) * smoothstep(0.00999999977648258209228515625 * g_DistortionWidth, 0.0, abs(fract(g_Time * g_DistortionSpeed) - in.v_TexCoord.y)), 0.0);
    distortion *= g_NoiseAlpha;
    float4 orig = g_Texture0.sample(g_Texture0Smplr, (in.v_TexCoord.xy + distortion));
    float4 albedo;
    albedo.y = orig.yw.x;
    albedo.w = orig.yw.y;
    albedo.x = g_Texture0.sample(g_Texture0Smplr, (in.v_TexCoordGlitch.xy + distortion)).x;
    albedo.z = g_Texture0.sample(g_Texture0Smplr, (in.v_TexCoordGlitch.zw + distortion)).z;
    float3 _noise = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoordNoise.xy).xyz;
    float3 _noise2 = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoordNoise.zw).yzx;
    _noise = fast::clamp(_noise * _noise2, float3(0.0), float3(1.0));
    float blend = 0.100000001490116119384765625;
    float3 param = albedo.xyz;
    float3 param_1 = _noise;
    float param_2 = blend;
    float3 _277 = ApplyBlending(12, param, param_1, param_2);
    albedo.x = _277.x;
    albedo.y = _277.y;
    albedo.z = _277.z;
    float4 _284 = albedo;
    float4 _286 = albedo;
    float3 _298 = mix(_284.xyz, fast::min(_286.xyz + smoothstep(float3(0.699999988079071044921875), float3(1.0), _noise), float3(1.0)), float3(blend));
    albedo.x = _298.x;
    albedo.y = _298.y;
    albedo.z = _298.z;
    float2 vhsNoise = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoordVHSNoise.xy).xy;
    float2 vhsNoise2 = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoordVHSNoise.zw).xy;
    float artifactLimiter = powr(g_ArtifactsScale, 0.20000000298023223876953125);
    float artifactsAlpha = ((step(0.89999997615814208984375, vhsNoise.x * artifactLimiter) * step(0.89999997615814208984375, vhsNoise2.x * artifactLimiter)) * vhsNoise.y) * vhsNoise2.y;
    float4 _342 = albedo;
    float4 _344 = albedo;
    float3 _350 = mix(_342.xyz, float3(1.0) - _344.xyz, float3(artifactsAlpha));
    albedo.x = _350.x;
    albedo.y = _350.y;
    albedo.z = _350.z;
    out.out_FragColor = mix(orig, albedo, float4(g_NoiseAlpha));
    return out;
}

