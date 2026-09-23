#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 v_TexCoord [[user(locn0)]];
    float3 v_RefractTexCoord [[user(locn1)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant float4x4& g_ModelViewProjectionMatrix [[buffer(0)]], constant float2& g_Scale [[buffer(1)]], constant float4& g_Texture1Resolution [[buffer(2)]], constant float& g_Strength [[buffer(3)]])
{
    main0_out out = {};
    out.gl_Position = float4(in.a_Position, 1.0) * g_ModelViewProjectionMatrix;
    out.v_TexCoord.x = in.a_TexCoord.x;
    out.v_TexCoord.y = in.a_TexCoord.y;
    float2 _49 = in.a_TexCoord * g_Scale;
    out.v_RefractTexCoord.x = _49.x;
    out.v_RefractTexCoord.y = _49.y;
    float _55 = out.v_TexCoord.x;
    float _67 = out.v_TexCoord.y;
    float2 _75 = float2((_55 * g_Texture1Resolution.z) / g_Texture1Resolution.x, (_67 * g_Texture1Resolution.w) / g_Texture1Resolution.y);
    out.v_TexCoord.z = _75.x;
    out.v_TexCoord.w = _75.y;
    out.v_RefractTexCoord.z = (sign(g_Strength) * g_Strength) * g_Strength;
    return out;
}

