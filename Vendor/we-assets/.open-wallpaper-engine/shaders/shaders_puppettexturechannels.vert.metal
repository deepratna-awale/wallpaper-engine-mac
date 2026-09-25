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

// Implementation of the GLSL mod() function, which is slightly different than Metal fmod()
template<typename Tx, typename Ty>
inline Tx mod(Tx x, Ty y)
{
    return x - y * floor(x / y);
}

struct main0_out
{
    float3 v_TexCoordBlend [[user(locn0)]];
    float2 v_TexCoordBase [[user(locn1)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float4 a_TexCoordVec4 [[attribute(1)]];
    uint4 a_BlendIndices [[attribute(2)]];
};

static inline __attribute__((always_inline))
float4 mul(thread const float4& value, thread const float4x4& matrix)
{
    return matrix * value;
}

vertex main0_out main0(main0_in in [[stage_in]], constant float4x4& g_ModelViewProjectionMatrix [[buffer(0)]], constant float4& g_Texture1Resolution [[buffer(1)]], constant spvUnsafeArray<float4, 1>& g_BlendMap [[buffer(2)]])
{
    main0_out out = {};
    float4 param = float4(in.a_Position, 1.0);
    float4x4 param_1 = g_ModelViewProjectionMatrix;
    out.gl_Position = mul(param, param_1);
    out.v_TexCoordBlend.x = in.a_TexCoordVec4.xy.x;
    out.v_TexCoordBlend.y = in.a_TexCoordVec4.xy.y;
    out.v_TexCoordBase = in.a_TexCoordVec4.zw * (g_Texture1Resolution.zw / g_Texture1Resolution.xy);
    out.v_TexCoordBlend.z = g_BlendMap[int(floor(float(in.a_BlendIndices.x) / 4.0))][int(mod(float(in.a_BlendIndices.x), 4.0))];
    return out;
}

