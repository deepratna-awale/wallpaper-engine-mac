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
    float2 v_TexCoord_0 [[user(locn0)]];
    float2 v_TexCoord_1 [[user(locn1)]];
    float2 v_TexCoord_2 [[user(locn2)]];
    float2 v_TexCoord_3 [[user(locn3)]];
};

fragment main0_out main0(main0_in in [[stage_in]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    spvUnsafeArray<float2, 4> v_TexCoord = {};
    v_TexCoord[0] = in.v_TexCoord_0;
    v_TexCoord[1] = in.v_TexCoord_1;
    v_TexCoord[2] = in.v_TexCoord_2;
    v_TexCoord[3] = in.v_TexCoord_3;
    float4 albedo = ((g_Texture0.sample(g_Texture0Smplr, v_TexCoord[0]) + g_Texture0.sample(g_Texture0Smplr, v_TexCoord[1])) + g_Texture0.sample(g_Texture0Smplr, v_TexCoord[2])) + g_Texture0.sample(g_Texture0Smplr, v_TexCoord[3]);
    albedo *= 0.25;
    out.out_FragColor = float4(albedo.xyz, 1.0);
    return out;
}

