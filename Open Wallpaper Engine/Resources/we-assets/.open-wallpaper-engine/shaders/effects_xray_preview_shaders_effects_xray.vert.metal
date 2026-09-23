#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 v_TexCoord [[user(locn0)]];
    float3 v_PointerUV [[user(locn1)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant float4x4& g_ModelViewProjectionMatrix [[buffer(0)]], constant float4& g_Texture1Resolution [[buffer(1)]], constant float2& g_PointerPosition [[buffer(2)]], constant float4x4& g_ModelViewProjectionMatrixInverse [[buffer(3)]], constant float4& g_Texture0Resolution [[buffer(4)]])
{
    main0_out out = {};
    out.gl_Position = float4(in.a_Position, 1.0) * g_ModelViewProjectionMatrix;
    out.v_TexCoord.x = in.a_TexCoord.x;
    out.v_TexCoord.y = in.a_TexCoord.y;
    float _44 = out.v_TexCoord.x;
    float _56 = out.v_TexCoord.y;
    float2 _64 = float2((_44 * g_Texture1Resolution.z) / g_Texture1Resolution.x, (_56 * g_Texture1Resolution.w) / g_Texture1Resolution.y);
    out.v_TexCoord.z = _64.x;
    out.v_TexCoord.w = _64.y;
    float2 pointer = g_PointerPosition;
    pointer.y = 1.0 - pointer.y;
    out.v_PointerUV = (float4((pointer * 2.0) - float2(1.0), 0.0, 1.0) * g_ModelViewProjectionMatrixInverse).xyw;
    float3 _99 = out.v_PointerUV;
    float2 _101 = _99.xy * (float2(1.0) / g_Texture0Resolution.xy);
    out.v_PointerUV.x = _101.x;
    out.v_PointerUV.y = _101.y;
    return out;
}

