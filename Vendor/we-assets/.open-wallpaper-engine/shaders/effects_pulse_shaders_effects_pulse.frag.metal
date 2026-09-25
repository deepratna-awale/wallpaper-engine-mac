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
    float v_Pulse [[user(locn1)]];
};

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return mix(A, fast::min(A + B, float3(1.0)), float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant float2& g_PulseThresholds [[buffer(0)]], constant float& g_Time [[buffer(1)]], constant float& g_PulseSpeed [[buffer(2)]], constant float& g_PulsePhase [[buffer(3)]], constant float& g_PulseAmount [[buffer(4)]], constant float& g_NoiseSpeed [[buffer(5)]], constant float& g_NoiseAmount [[buffer(6)]], constant float& g_Power [[buffer(7)]], constant float3& g_TintColor1 [[buffer(8)]], constant float3& g_TintColor2 [[buffer(9)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float4 sampleValue = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float4 albedo = sampleValue;
    float pulse = 0.0;
    pulse = in.v_Pulse;
    pulse = smoothstep(g_PulseThresholds.x, g_PulseThresholds.y, (sin((g_Time * g_PulseSpeed) + (g_PulsePhase - 1.57079637050628662109375)) * 0.5) + 0.5) * g_PulseAmount;
    float _noise = g_Texture1.sample(g_Texture1Smplr, (float2(g_Time * 0.08333332836627960205078125, g_Time * 0.02777777053415775299072265625) * g_NoiseSpeed)).x * g_NoiseAmount;
    pulse += _noise;
    pulse = powr(pulse, g_Power);
    float3 param = albedo.xyz * g_TintColor1;
    float3 param_1 = albedo.xyz * g_TintColor2;
    float param_2 = pulse;
    float3 _126 = ApplyBlending(9, param, param_1, param_2);
    albedo.x = _126.x;
    albedo.y = _126.y;
    albedo.z = _126.z;
    out.out_FragColor = float4(fast::max(float3(0.0), albedo.xyz), albedo.w);
    return out;
}

