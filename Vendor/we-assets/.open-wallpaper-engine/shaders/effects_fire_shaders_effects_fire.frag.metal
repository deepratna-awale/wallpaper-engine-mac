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
};

static inline __attribute__((always_inline))
float3 ApplyBlending(thread const int& mode, thread const float3& base, thread const float3& blend, thread const float& amount)
{
    return mix(base, blend, float3(fast::clamp(amount, 0.0, 1.0)));
}

fragment main0_out main0(main0_in in [[stage_in]], constant float& g_Time [[buffer(0)]], constant float& g_FlowSpeed [[buffer(1)]], constant float& g_CloudScale [[buffer(2)]], constant float& g_CloudLOD [[buffer(3)]], constant float& g_Distortion [[buffer(4)]], constant float3& g_Color2 [[buffer(5)]], constant float3& g_Color1 [[buffer(6)]], constant float& g_CloudThreshold [[buffer(7)]], constant float& g_CloudFeather [[buffer(8)]], constant float& g_CloudsAlpha [[buffer(9)]], texture2d<float> g_Texture1 [[texture(0)]], texture2d<float> g_Texture2 [[texture(1)]], texture2d<float> g_Texture0 [[texture(2)]], sampler g_Texture1Smplr [[sampler(0)]], sampler g_Texture2Smplr [[sampler(1)]], sampler g_Texture0Smplr [[sampler(2)]])
{
    main0_out out = {};
    float2 flowColors = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.zw).xy;
    float2 flowMask = (flowColors - float2(0.4979999959468841552734375)) * 2.0;
    float scaledTime = g_Time * g_FlowSpeed;
    float2 cycles = float2(fract(scaledTime), fract(scaledTime + 0.5));
    float blend = 2.0 * abs(cycles.x - 0.5);
    float2 flowUVOffset1 = ((flowMask * g_CloudScale) * 0.1500000059604644775390625) * (cycles.x - 0.5);
    float2 flowUVOffset2 = ((flowMask * g_CloudScale) * 0.1500000059604644775390625) * (cycles.y - 0.5);
    float cloudBackground = g_Texture2.sample(g_Texture2Smplr, ((in.v_TexCoord.xy * g_CloudScale) + float2(scaledTime * 0.100000001490116119384765625)), level(g_CloudLOD)).x;
    float cloud0 = g_Texture2.sample(g_Texture2Smplr, ((in.v_TexCoord.xy * g_CloudScale) + flowUVOffset1), level(g_CloudLOD)).x;
    float cloud1 = g_Texture2.sample(g_Texture2Smplr, ((in.v_TexCoord.xy * g_CloudScale) + flowUVOffset2), level(g_CloudLOD)).x;
    float streamNoise = mix(cloud0, cloud1, blend);
    float2 baseUV = in.v_TexCoord.xy;
    float flowMaskLength = powr(length(flowMask), 2.0);
    baseUV += (((((mix(flowMask, -flowMask, float2(streamNoise)) * cloudBackground) * 0.5) * streamNoise) * flowMaskLength) * g_Distortion);
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, baseUV);
    streamNoise = fract(streamNoise + (scaledTime * 0.20000000298023223876953125));
    float colorNoise = smoothstep(0.0, 0.5, streamNoise) * smoothstep(1.0, 0.5, streamNoise);
    float3 cloudColor = mix(g_Color2, g_Color1, float3(colorNoise));
    float blendNoise = mix(colorNoise * flowMaskLength, 1.0, powr(flowMaskLength, 4.0));
    blendNoise = smoothstep(g_CloudThreshold, g_CloudThreshold + g_CloudFeather, blendNoise);
    float streamBlend = g_CloudsAlpha * blendNoise;
    int param = 0;
    float3 param_1 = albedo.xyz;
    float3 param_2 = cloudColor;
    float param_3 = streamBlend;
    float3 _220 = ApplyBlending(param, param_1, param_2, param_3);
    albedo.x = _220.x;
    albedo.y = _220.y;
    albedo.z = _220.z;
    out.out_FragColor = albedo;
    return out;
}

