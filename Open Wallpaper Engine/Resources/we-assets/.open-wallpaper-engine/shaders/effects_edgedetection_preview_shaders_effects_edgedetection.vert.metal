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
    float2 v_TexCoordKernel_0 [[user(locn0)]];
    float2 v_TexCoordKernel_1 [[user(locn1)]];
    float2 v_TexCoordKernel_2 [[user(locn2)]];
    float2 v_TexCoordKernel_3 [[user(locn3)]];
    float2 v_TexCoordKernel_4 [[user(locn4)]];
    float2 v_TexCoordKernel_5 [[user(locn5)]];
    float2 v_TexCoordKernel_6 [[user(locn6)]];
    float2 v_TexCoordKernel_7 [[user(locn7)]];
    float2 v_TexCoordKernel_8 [[user(locn8)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant float4x4& g_ModelViewProjectionMatrix [[buffer(0)]], constant float4& g_Texture0Resolution [[buffer(1)]], constant float& g_DetectionSize [[buffer(2)]])
{
    main0_out out = {};
    spvUnsafeArray<float2, 9> v_TexCoordKernel = {};
    out.gl_Position = float4(in.a_Position, 1.0) * g_ModelViewProjectionMatrix;
    float2 texelSize = float2(1.0 / g_Texture0Resolution.z, 1.0 / g_Texture0Resolution.w) * g_DetectionSize;
    v_TexCoordKernel[0] = in.a_TexCoord - texelSize;
    v_TexCoordKernel[1] = in.a_TexCoord - float2(0.0, texelSize.y);
    v_TexCoordKernel[2] = in.a_TexCoord + float2(texelSize.x, -texelSize.y);
    v_TexCoordKernel[3] = in.a_TexCoord - float2(texelSize.x, 0.0);
    v_TexCoordKernel[4] = in.a_TexCoord;
    v_TexCoordKernel[5] = in.a_TexCoord + float2(texelSize.x, 0.0);
    v_TexCoordKernel[6] = in.a_TexCoord + float2(-texelSize.x, texelSize.y);
    v_TexCoordKernel[7] = in.a_TexCoord + float2(0.0, texelSize.y);
    v_TexCoordKernel[8] = in.a_TexCoord + texelSize;
    out.v_TexCoordKernel_0 = v_TexCoordKernel[0];
    out.v_TexCoordKernel_1 = v_TexCoordKernel[1];
    out.v_TexCoordKernel_2 = v_TexCoordKernel[2];
    out.v_TexCoordKernel_3 = v_TexCoordKernel[3];
    out.v_TexCoordKernel_4 = v_TexCoordKernel[4];
    out.v_TexCoordKernel_5 = v_TexCoordKernel[5];
    out.v_TexCoordKernel_6 = v_TexCoordKernel[6];
    out.v_TexCoordKernel_7 = v_TexCoordKernel[7];
    out.v_TexCoordKernel_8 = v_TexCoordKernel[8];
    return out;
}

