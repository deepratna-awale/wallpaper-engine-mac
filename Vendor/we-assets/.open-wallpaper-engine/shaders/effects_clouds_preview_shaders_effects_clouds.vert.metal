#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 v_TexCoord [[user(locn0)]];
    float4 v_TexCoordClouds [[user(locn1)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant float4x4& g_ModelViewProjectionMatrix [[buffer(0)]], constant float4& g_Texture0Resolution [[buffer(1)]], constant float& g_Time [[buffer(2)]], constant float2& g_CloudSpeeds [[buffer(3)]], constant float2& g_CloudScales [[buffer(4)]])
{
    main0_out out = {};
    out.gl_Position = float4(in.a_Position, 1.0) * g_ModelViewProjectionMatrix;
    out.v_TexCoord = in.a_TexCoord.xyxy;
    float aspect = g_Texture0Resolution.z / g_Texture0Resolution.w;
    float2 _65 = (in.a_TexCoord + float2(g_Time * g_CloudSpeeds.x)) * g_CloudScales.x;
    out.v_TexCoordClouds.x = _65.x;
    out.v_TexCoordClouds.y = _65.y;
    float2 _80 = (in.a_TexCoord + float2(g_Time * g_CloudSpeeds.y)) * g_CloudScales.y;
    out.v_TexCoordClouds.z = _80.x;
    out.v_TexCoordClouds.w = _80.y;
    float _86 = out.v_TexCoordClouds.w;
    float _89 = out.v_TexCoordClouds.z;
    float2 _90 = float2(-_86, _89);
    out.v_TexCoordClouds.z = _90.x;
    out.v_TexCoordClouds.w = _90.y;
    return out;
}

