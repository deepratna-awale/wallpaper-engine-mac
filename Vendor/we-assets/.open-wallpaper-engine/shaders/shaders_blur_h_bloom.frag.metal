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
    float2 v_TexCoord_4 [[user(locn4)]];
    float2 v_TexCoord_5 [[user(locn5)]];
    float2 v_TexCoord_6 [[user(locn6)]];
    float2 v_TexCoord_7 [[user(locn7)]];
    float2 v_TexCoord_8 [[user(locn8)]];
    float2 v_TexCoord_9 [[user(locn9)]];
    float2 v_TexCoord_10 [[user(locn10)]];
    float2 v_TexCoord_11 [[user(locn11)]];
    float2 v_TexCoord_12 [[user(locn12)]];
};

fragment main0_out main0(main0_in in [[stage_in]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    spvUnsafeArray<float2, 13> v_TexCoord = {};
    v_TexCoord[0] = in.v_TexCoord_0;
    v_TexCoord[1] = in.v_TexCoord_1;
    v_TexCoord[2] = in.v_TexCoord_2;
    v_TexCoord[3] = in.v_TexCoord_3;
    v_TexCoord[4] = in.v_TexCoord_4;
    v_TexCoord[5] = in.v_TexCoord_5;
    v_TexCoord[6] = in.v_TexCoord_6;
    v_TexCoord[7] = in.v_TexCoord_7;
    v_TexCoord[8] = in.v_TexCoord_8;
    v_TexCoord[9] = in.v_TexCoord_9;
    v_TexCoord[10] = in.v_TexCoord_10;
    v_TexCoord[11] = in.v_TexCoord_11;
    v_TexCoord[12] = in.v_TexCoord_12;
    float3 _124 = (((((((((((g_Texture0.sample(g_Texture0Smplr, v_TexCoord[0]).xyz * 0.0062989997677505016326904296875) + (g_Texture0.sample(g_Texture0Smplr, v_TexCoord[1]).xyz * 0.01729799993336200714111328125)) + (g_Texture0.sample(g_Texture0Smplr, v_TexCoord[2]).xyz * 0.0395330004394054412841796875)) + (g_Texture0.sample(g_Texture0Smplr, v_TexCoord[3]).xyz * 0.075189001858234405517578125)) + (g_Texture0.sample(g_Texture0Smplr, v_TexCoord[4]).xyz * 0.119006998836994171142578125)) + (g_Texture0.sample(g_Texture0Smplr, v_TexCoord[5]).xyz * 0.15675599873065948486328125)) + (g_Texture0.sample(g_Texture0Smplr, v_TexCoord[6]).xyz * 0.17183400690555572509765625)) + (g_Texture0.sample(g_Texture0Smplr, v_TexCoord[7]).xyz * 0.15675599873065948486328125)) + (g_Texture0.sample(g_Texture0Smplr, v_TexCoord[8]).xyz * 0.119006998836994171142578125)) + (g_Texture0.sample(g_Texture0Smplr, v_TexCoord[9]).xyz * 0.075189001858234405517578125)) + (g_Texture0.sample(g_Texture0Smplr, v_TexCoord[10]).xyz * 0.0395330004394054412841796875)) + (g_Texture0.sample(g_Texture0Smplr, v_TexCoord[11]).xyz * 0.01729799993336200714111328125);
    float3 albedo = _124 + (g_Texture0.sample(g_Texture0Smplr, v_TexCoord[12]).xyz * 0.0062989997677505016326904296875);
    out.out_FragColor = float4(albedo, 1.0);
    return out;
}

