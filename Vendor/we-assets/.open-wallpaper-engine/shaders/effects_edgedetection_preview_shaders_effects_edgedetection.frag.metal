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
    float2 v_TexCoordKernel_0 [[user(locn0)]];
    float2 v_TexCoordKernel_1 [[user(locn1)]];
    float2 v_TexCoordKernel_2 [[user(locn2)]];
    float2 v_TexCoordKernel_3 [[user(locn3)]];
    float2 v_TexCoordKernel_4 [[user(locn4)]];
    float2 v_TexCoordKernel_5 [[user(locn5)]];
    float2 v_TexCoordKernel_6 [[user(locn6)]];
    float2 v_TexCoordKernel_7 [[user(locn7)]];
    float2 v_TexCoordKernel_8 [[user(locn8)]];
};

static inline __attribute__((always_inline))
float greyscale(thread const float3& color)
{
    return dot(color, float3(0.10999999940395355224609375, 0.589999973773956298828125, 0.300000011920928955078125));
}

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return mix(A, B, float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant float3& g_OutlineColor2 [[buffer(0)]], constant float3& g_OutlineColor1 [[buffer(1)]], constant float& g_DetectionThreshold [[buffer(2)]], constant float& g_DetectionMultiply [[buffer(3)]], constant float& g_BlendAlpha [[buffer(4)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    spvUnsafeArray<float2, 9> v_TexCoordKernel = {};
    v_TexCoordKernel[0] = in.v_TexCoordKernel_0;
    v_TexCoordKernel[1] = in.v_TexCoordKernel_1;
    v_TexCoordKernel[2] = in.v_TexCoordKernel_2;
    v_TexCoordKernel[3] = in.v_TexCoordKernel_3;
    v_TexCoordKernel[4] = in.v_TexCoordKernel_4;
    v_TexCoordKernel[5] = in.v_TexCoordKernel_5;
    v_TexCoordKernel[6] = in.v_TexCoordKernel_6;
    v_TexCoordKernel[7] = in.v_TexCoordKernel_7;
    v_TexCoordKernel[8] = in.v_TexCoordKernel_8;
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, v_TexCoordKernel[4]);
    float3 sample00 = g_Texture0.sample(g_Texture0Smplr, v_TexCoordKernel[0]).xyz;
    float3 sample10 = g_Texture0.sample(g_Texture0Smplr, v_TexCoordKernel[1]).xyz;
    float3 sample20 = g_Texture0.sample(g_Texture0Smplr, v_TexCoordKernel[2]).xyz;
    float3 sample01 = g_Texture0.sample(g_Texture0Smplr, v_TexCoordKernel[3]).xyz;
    float3 sample21 = g_Texture0.sample(g_Texture0Smplr, v_TexCoordKernel[5]).xyz;
    float3 sample02 = g_Texture0.sample(g_Texture0Smplr, v_TexCoordKernel[6]).xyz;
    float3 sample12 = g_Texture0.sample(g_Texture0Smplr, v_TexCoordKernel[7]).xyz;
    float3 sample22 = g_Texture0.sample(g_Texture0Smplr, v_TexCoordKernel[8]).xyz;
    float3 gx = (((sample20 - sample00) + ((sample21 - sample01) * 2.0)) + sample22) - sample02;
    float3 gy = (((sample00 - sample02) + ((sample10 - sample12) * 2.0)) + sample20) - sample22;
    float3 param = gx;
    float3 param_1 = gy;
    float g = abs(greyscale(param)) + abs(greyscale(param_1));
    float3 combinedColor = mix(g_OutlineColor2, g_OutlineColor1, float3(fast::min(1.0, fast::max(0.0, g - g_DetectionThreshold) * g_DetectionMultiply)));
    out.out_FragColor.w = albedo.w;
    float3 param_2 = albedo.xyz;
    float3 param_3 = combinedColor;
    float param_4 = g_BlendAlpha;
    float3 _184 = ApplyBlending(0, param_2, param_3, param_4);
    out.out_FragColor.x = _184.x;
    out.out_FragColor.y = _184.y;
    out.out_FragColor.z = _184.z;
    return out;
}

