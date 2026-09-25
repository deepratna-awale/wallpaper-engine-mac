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
    uint we_ViewportIndex [[user(locn0)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
};

static inline __attribute__((always_inline))
float4 mul(thread const float4& value, thread const float4x4& matrix)
{
    return matrix * value;
}

static inline __attribute__((always_inline))
void ApplyPosition(thread const float3& position, thread float4& worldPosition, constant float4x4& g_ModelMatrix)
{
    float4 param = float4(position, 1.0);
    float4x4 param_1 = g_ModelMatrix;
    worldPosition = mul(param, param_1);
}

vertex main0_out main0(main0_in in [[stage_in]], constant float4x4& g_ModelMatrix [[buffer(0)]], constant spvUnsafeArray<float4x4, 6>& g_ViewportViewProjectionMatrices [[buffer(1)]], uint gl_InstanceID [[instance_id]])
{
    main0_out out = {};
    float3 localPos = in.a_Position;
    float3 param = localPos;
    float4 param_1;
    ApplyPosition(param, param_1, g_ModelMatrix);
    float4 worldPos = param_1;
    float4 param_2 = worldPos;
    float4x4 param_3 = g_ViewportViewProjectionMatrices[gl_InstanceID];
    out.gl_Position = mul(param_2, param_3);
    out.we_ViewportIndex = uint(gl_InstanceID);
    return out;
}

