#pragma clang diagnostic ignored "-Wmissing-prototypes"
#pragma clang diagnostic ignored "-Wmissing-braces"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

template<typename T, size_t Num>
struct spvUnsafeArray
{
    T elements[Num ? Num : 1];
    
    thread T& operator [] (size_t pos) thread
    {
        return elements[pos];
    }
    constexpr const thread T& operator [] (size_t pos) const thread
    {
        return elements[pos];
    }
    
    device T& operator [] (size_t pos) device
    {
        return elements[pos];
    }
    constexpr const device T& operator [] (size_t pos) const device
    {
        return elements[pos];
    }
    
    constexpr const constant T& operator [] (size_t pos) const constant
    {
        return elements[pos];
    }
    
    threadgroup T& operator [] (size_t pos) threadgroup
    {
        return elements[pos];
    }
    constexpr const threadgroup T& operator [] (size_t pos) const threadgroup
    {
        return elements[pos];
    }
};

struct main0_out
{
    float4 out_FragColor [[color(0)]];
};

struct main0_in
{
    float2 v_TexCoord [[user(locn0)]];
};

static inline __attribute__((always_inline))
float mod2(thread const float& x, thread const float& y)
{
    return x - (y * floor(x / y));
}

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return mix(A, B, float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant float& u_BarCount [[buffer(0)]], constant spvUnsafeArray<float, 32>& g_AudioSpectrum32Left [[buffer(1)]], constant spvUnsafeArray<float, 32>& g_AudioSpectrum32Right [[buffer(33)]], constant float2& u_BarBounds [[buffer(65)]], constant float& u_BarSpacing [[buffer(66)]], constant float3& u_BarColor [[buffer(67)]], constant float& u_BarOpacity [[buffer(68)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float2 shapeCoord = in.v_TexCoord;
    float barDist = abs((fract(shapeCoord.x * u_BarCount) * 2.0) - 1.0);
    float frequency = (floor(shapeCoord.x * u_BarCount) / u_BarCount) * 32.0;
    float param = frequency;
    float param_1 = 32.0;
    float barFreq1 = mod2(param, param_1);
    float param_2 = barFreq1 + 1.0;
    float param_3 = 32.0;
    float barFreq2 = mod2(param_2, param_3);
    float barVolume1 = (g_AudioSpectrum32Left[int(barFreq1)] + g_AudioSpectrum32Right[int(barFreq1)]) * 0.5;
    float barVolume2 = (g_AudioSpectrum32Left[int(barFreq2)] + g_AudioSpectrum32Right[int(barFreq2)]) * 0.5;
    float barVolume = mix(barVolume1, barVolume2, smoothstep(0.0, 1.0, fract(frequency)));
    float barHeight = mix(u_BarBounds.x, u_BarBounds.y, barVolume);
    float bar = step(1.0 - shapeCoord.y, barHeight);
    bar *= step(barDist, 1.0 - u_BarSpacing);
    float3 finalColor = u_BarColor;
    float4 scene = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float3 param_4 = mix(finalColor, scene.xyz, float3(scene.w));
    float3 param_5 = finalColor;
    float param_6 = bar * u_BarOpacity;
    finalColor = ApplyBlending(0, param_4, param_5, param_6);
    float alpha = bar * u_BarOpacity;
    out.out_FragColor = float4(finalColor, alpha);
    return out;
}

