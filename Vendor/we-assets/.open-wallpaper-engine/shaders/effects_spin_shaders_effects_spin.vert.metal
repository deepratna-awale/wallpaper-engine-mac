#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 v_TexCoord [[user(locn0)]];
    float2 v_TexCoordSoftMask [[user(locn1)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

static inline __attribute__((always_inline))
float4 mul(thread const float4& value, thread const float4x4& matrix)
{
    return matrix * value;
}

static inline __attribute__((always_inline))
float2 rotateVec2(thread const float2& value, thread const float& angle)
{
    float s = sin(angle);
    float c = cos(angle);
    return float2((value.x * c) - (value.y * s), (value.x * s) + (value.y * c));
}

vertex main0_out main0(main0_in in [[stage_in]], constant float4& g_Texture0Resolution [[buffer(0)]], constant float4x4& g_ModelViewProjectionMatrix [[buffer(1)]], constant float2& g_SpinCenter [[buffer(2)]], constant float& g_Phase [[buffer(3)]], constant float& g_Speed [[buffer(4)]], constant float& g_Time [[buffer(5)]])
{
    main0_out out = {};
    float aspect = g_Texture0Resolution.z / g_Texture0Resolution.w;
    float3 position = in.a_Position;
    float4 param = float4(position, 1.0);
    float4x4 param_1 = g_ModelViewProjectionMatrix;
    out.gl_Position = mul(param, param_1);
    out.v_TexCoord = in.a_TexCoord.xyxy;
    float4 _104 = out.v_TexCoord;
    float2 _106 = _104.xy - g_SpinCenter;
    out.v_TexCoord.x = _106.x;
    out.v_TexCoord.y = _106.y;
    out.v_TexCoord.x *= aspect;
    out.v_TexCoordSoftMask = out.v_TexCoord.xy;
    float offset = g_Phase * 6.283185482025146484375;
    float2 param_2 = out.v_TexCoord.xy;
    float param_3 = (g_Speed * g_Time) + offset;
    float2 _137 = rotateVec2(param_2, param_3);
    out.v_TexCoord.x = _137.x;
    out.v_TexCoord.y = _137.y;
    out.v_TexCoord.x /= aspect;
    float4 _148 = out.v_TexCoord;
    float2 _150 = _148.xy + g_SpinCenter;
    out.v_TexCoord.x = _150.x;
    out.v_TexCoord.y = _150.y;
    out.v_TexCoordSoftMask += g_SpinCenter;
    return out;
}

