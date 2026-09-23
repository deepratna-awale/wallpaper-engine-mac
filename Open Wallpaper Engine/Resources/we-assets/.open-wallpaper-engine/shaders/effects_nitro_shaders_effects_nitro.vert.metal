#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 v_TexCoord [[user(locn0)]];
    float4 v_TexCoordNitro [[user(locn1)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant float4x4& g_ModelViewProjectionMatrix [[buffer(0)]], constant float4& g_Texture0Resolution [[buffer(1)]], constant float2& g_NitroScales [[buffer(2)]], constant float& g_Time [[buffer(3)]], constant float4& g_NitroSpeeds [[buffer(4)]])
{
    main0_out out = {};
    out.gl_Position = float4(in.a_Position, 1.0) * g_ModelViewProjectionMatrix;
    out.v_TexCoord = in.a_TexCoord.xyxy;
    float aspect = g_Texture0Resolution.z / g_Texture0Resolution.w;
    float2 _64 = (in.a_TexCoord * g_NitroScales.x) + (g_NitroSpeeds.xy * g_Time);
    out.v_TexCoordNitro.x = _64.x;
    out.v_TexCoordNitro.y = _64.y;
    float2 _78 = (in.a_TexCoord * g_NitroScales.y) + (g_NitroSpeeds.zw * g_Time);
    out.v_TexCoordNitro.z = _78.x;
    out.v_TexCoordNitro.w = _78.y;
    float4 _84 = out.v_TexCoordNitro;
    float2 _86 = _84.xz * aspect;
    out.v_TexCoordNitro.x = _86.x;
    out.v_TexCoordNitro.z = _86.y;
    float _92 = out.v_TexCoordNitro.w;
    float _95 = out.v_TexCoordNitro.z;
    float2 _96 = float2(-_92, _95);
    out.v_TexCoordNitro.z = _96.x;
    out.v_TexCoordNitro.w = _96.y;
    return out;
}

