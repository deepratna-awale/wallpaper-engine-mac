#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 v_TexCoord [[user(locn0)]];
    float4 v_TexCoordRipple [[user(locn1)]];
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

vertex main0_out main0(main0_in in [[stage_in]], constant float4x4& g_ModelViewProjectionMatrix [[buffer(0)]], constant float& g_Direction [[buffer(1)]], constant float& g_ScrollSpeed [[buffer(2)]], constant float& g_Time [[buffer(3)]], constant float& g_AnimationSpeed [[buffer(4)]], constant float& g_Scale [[buffer(5)]], constant float4& g_Texture0Resolution [[buffer(6)]], constant float4& g_Texture2Resolution [[buffer(7)]])
{
    main0_out out = {};
    float4 param = float4(in.a_Position, 1.0);
    float4x4 param_1 = g_ModelViewProjectionMatrix;
    out.gl_Position = mul(param, param_1);
    out.v_TexCoord.x = in.a_TexCoord.x;
    out.v_TexCoord.y = in.a_TexCoord.y;
    float piFrac = 0.3926990926265716552734375;
    float pi = 3.1410000324249267578125;
    float2 coordsRotated = out.v_TexCoord.xy;
    float2 coordsRotated2 = out.v_TexCoord.xy * 1.3329999446868896484375;
    float2 param_2 = float2(0.0, -1.0);
    float param_3 = g_Direction;
    float2 scroll = ((rotateVec2(param_2, param_3) * g_ScrollSpeed) * g_ScrollSpeed) * g_Time;
    float2 _132 = (coordsRotated + float2((g_Time * g_AnimationSpeed) * g_AnimationSpeed)) + scroll;
    out.v_TexCoordRipple.x = _132.x;
    out.v_TexCoordRipple.y = _132.y;
    float2 _146 = (coordsRotated2 - float2((g_Time * g_AnimationSpeed) * g_AnimationSpeed)) + scroll;
    out.v_TexCoordRipple.z = _146.x;
    out.v_TexCoordRipple.w = _146.y;
    out.v_TexCoordRipple *= g_Scale;
    float rippleTextureAdjustment = g_Texture0Resolution.x / g_Texture0Resolution.y;
    float4 _166 = out.v_TexCoordRipple;
    float2 _168 = _166.xz * rippleTextureAdjustment;
    out.v_TexCoordRipple.x = _168.x;
    out.v_TexCoordRipple.z = _168.y;
    float _174 = out.v_TexCoord.x;
    float _183 = out.v_TexCoord.y;
    float2 _190 = float2((_174 * g_Texture2Resolution.z) / g_Texture2Resolution.x, (_183 * g_Texture2Resolution.w) / g_Texture2Resolution.y);
    out.v_TexCoord.z = _190.x;
    out.v_TexCoord.w = _190.y;
    return out;
}

