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
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant float2& g_TexelSize [[buffer(0)]])
{
    main0_out out = {};
    spvUnsafeArray<float2, 13> v_TexCoord = {};
    out.gl_Position = float4(in.a_Position, 1.0);
    float localTexel = g_TexelSize.x * 8.0;
    v_TexCoord[0] = float2(in.a_TexCoord.x - (localTexel * 6.0), in.a_TexCoord.y);
    v_TexCoord[1] = float2(in.a_TexCoord.x - (localTexel * 5.0), in.a_TexCoord.y);
    v_TexCoord[2] = float2(in.a_TexCoord.x - (localTexel * 4.0), in.a_TexCoord.y);
    v_TexCoord[3] = float2(in.a_TexCoord.x - (localTexel * 3.0), in.a_TexCoord.y);
    v_TexCoord[4] = float2(in.a_TexCoord.x - (localTexel * 2.0), in.a_TexCoord.y);
    v_TexCoord[5] = float2(in.a_TexCoord.x - localTexel, in.a_TexCoord.y);
    v_TexCoord[6] = float2(in.a_TexCoord.x, in.a_TexCoord.y);
    v_TexCoord[7] = float2(in.a_TexCoord.x + localTexel, in.a_TexCoord.y);
    v_TexCoord[8] = float2(in.a_TexCoord.x + (localTexel * 2.0), in.a_TexCoord.y);
    v_TexCoord[9] = float2(in.a_TexCoord.x + (localTexel * 3.0), in.a_TexCoord.y);
    v_TexCoord[10] = float2(in.a_TexCoord.x + (localTexel * 4.0), in.a_TexCoord.y);
    v_TexCoord[11] = float2(in.a_TexCoord.x + (localTexel * 5.0), in.a_TexCoord.y);
    v_TexCoord[12] = float2(in.a_TexCoord.x + (localTexel * 6.0), in.a_TexCoord.y);
    out.v_TexCoord_0 = v_TexCoord[0];
    out.v_TexCoord_1 = v_TexCoord[1];
    out.v_TexCoord_2 = v_TexCoord[2];
    out.v_TexCoord_3 = v_TexCoord[3];
    out.v_TexCoord_4 = v_TexCoord[4];
    out.v_TexCoord_5 = v_TexCoord[5];
    out.v_TexCoord_6 = v_TexCoord[6];
    out.v_TexCoord_7 = v_TexCoord[7];
    out.v_TexCoord_8 = v_TexCoord[8];
    out.v_TexCoord_9 = v_TexCoord[9];
    out.v_TexCoord_10 = v_TexCoord[10];
    out.v_TexCoord_11 = v_TexCoord[11];
    out.v_TexCoord_12 = v_TexCoord[12];
    return out;
}

