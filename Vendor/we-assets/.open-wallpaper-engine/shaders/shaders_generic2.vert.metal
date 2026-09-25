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
    float3 v_Normal [[user(locn0)]];
    float3 v_ViewDir [[user(locn1)]];
    float2 v_TexCoord [[user(locn2)]];
    float4 v_Light0DirectionL3X [[user(locn3)]];
    float4 v_Light1DirectionL3Y [[user(locn4)]];
    float4 v_Light2DirectionL3Z [[user(locn5)]];
    float3 v_LightAmbientColor [[user(locn6)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float3 a_Normal [[attribute(1)]];
    float2 a_TexCoord [[attribute(2)]];
};

static inline __attribute__((always_inline))
float4 mul(thread const float4& value, thread const float4x4& matrix)
{
    return matrix * value;
}

static inline __attribute__((always_inline))
float3 mul(thread const float3& value, thread const float3x3& matrix)
{
    return matrix * value;
}

vertex main0_out main0(main0_in in [[stage_in]], constant float4x4& g_ModelMatrix [[buffer(0)]], constant float4x4& g_ViewProjectionMatrix [[buffer(1)]], constant float3& g_EyePosition [[buffer(2)]], constant spvUnsafeArray<float3, 4>& g_LightsPosition [[buffer(3)]], constant float3& g_LightSkylightColor [[buffer(7)]], constant float3& g_LightAmbientColor [[buffer(8)]])
{
    main0_out out = {};
    float4 param = float4(in.a_Position, 1.0);
    float4x4 param_1 = g_ModelMatrix;
    float4 worldPos = mul(param, param_1);
    float4 param_2 = worldPos;
    float4x4 param_3 = g_ViewProjectionMatrix;
    out.gl_Position = mul(param_2, param_3);
    float3 param_4 = in.a_Normal;
    float3x3 param_5 = float3x3(g_ModelMatrix[0].xyz, g_ModelMatrix[1].xyz, g_ModelMatrix[2].xyz);
    float3 normal = fast::normalize(mul(param_4, param_5));
    out.v_TexCoord = in.a_TexCoord;
    out.v_ViewDir = g_EyePosition - worldPos.xyz;
    float3 _104 = g_LightsPosition[0] - worldPos.xyz;
    out.v_Light0DirectionL3X.x = _104.x;
    out.v_Light0DirectionL3X.y = _104.y;
    out.v_Light0DirectionL3X.z = _104.z;
    float3 _120 = g_LightsPosition[1] - worldPos.xyz;
    out.v_Light1DirectionL3Y.x = _120.x;
    out.v_Light1DirectionL3Y.y = _120.y;
    out.v_Light1DirectionL3Y.z = _120.z;
    float3 _133 = g_LightsPosition[2] - worldPos.xyz;
    out.v_Light2DirectionL3Z.x = _133.x;
    out.v_Light2DirectionL3Z.y = _133.y;
    out.v_Light2DirectionL3Z.z = _133.z;
    float3 l3 = g_LightsPosition[3] - worldPos.xyz;
    out.v_Normal = normal;
    out.v_Light0DirectionL3X.w = l3.x;
    out.v_Light1DirectionL3Y.w = l3.y;
    out.v_Light2DirectionL3Z.w = l3.z;
    out.v_LightAmbientColor = mix(g_LightSkylightColor, g_LightAmbientColor, float3((dot(normal, float3(0.0, 1.0, 0.0)) * 0.5) + 0.5));
    return out;
}

