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

fragment main0_out main0(main0_in in [[stage_in]], constant float2& g_PulseThresholds [[buffer(0)]], constant float& g_Time [[buffer(1)]], constant float& g_PulseSpeed [[buffer(2)]], constant float& g_PulseAmount [[buffer(3)]], constant float& g_NoiseSpeed [[buffer(4)]], constant float& g_NoiseAmount [[buffer(5)]], constant float& g_Power [[buffer(6)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float pulse = smoothstep(g_PulseThresholds.x, g_PulseThresholds.y, (sin(g_Time * g_PulseSpeed) * 0.5) + 0.5) * g_PulseAmount;
    float _noise = g_Texture1.sample(g_Texture1Smplr, (float2(g_Time, g_Time * 0.333000004291534423828125) * g_NoiseSpeed)).x * g_NoiseAmount;
    pulse += _noise;
    pulse = powr(pulse, g_Power);
    out.out_FragColor = fast::clamp(albedo, float4(0.0), float4(1.0));
    return out;
}

