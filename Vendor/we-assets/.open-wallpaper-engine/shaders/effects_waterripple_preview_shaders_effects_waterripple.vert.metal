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
float2 rotateVec2(thread const float2& v, thread const float& r)
{
    float2 cs = float2(cos(r), sin(r));
    return float2((v.x * cs.x) - (v.y * cs.y), (v.x * cs.y) + (v.y * cs.x));
}

vertex main0_out main0(main0_in in [[stage_in]], constant float4x4& g_ModelViewProjectionMatrix [[buffer(0)]], constant float& g_Direction [[buffer(1)]], constant float& g_ScrollSpeed [[buffer(2)]], constant float& g_Time [[buffer(3)]], constant float& g_AnimationSpeed [[buffer(4)]], constant float& g_Scale [[buffer(5)]], constant float4& g_Texture0Resolution [[buffer(6)]], constant float4& g_Texture2Resolution [[buffer(7)]])
{
    main0_out out = {};
    out.gl_Position = float4(in.a_Position, 1.0) * g_ModelViewProjectionMatrix;
    out.v_TexCoord.x = in.a_TexCoord.x;
    out.v_TexCoord.y = in.a_TexCoord.y;
    float piFrac = 0.3926990926265716552734375;
    float pi = 3.1410000324249267578125;
    float2 coordsRotated = out.v_TexCoord.xy;
    float2 coordsRotated2 = out.v_TexCoord.xy * 1.3329999446868896484375;
    float2 param = float2(0.0, -1.0);
    float param_1 = g_Direction;
    float2 scroll = ((rotateVec2(param, param_1) * g_ScrollSpeed) * g_ScrollSpeed) * g_Time;
    float2 _122 = (coordsRotated + float2((g_Time * g_AnimationSpeed) * g_AnimationSpeed)) + scroll;
    out.v_TexCoordRipple.x = _122.x;
    out.v_TexCoordRipple.y = _122.y;
    float2 _136 = (coordsRotated2 - float2((g_Time * g_AnimationSpeed) * g_AnimationSpeed)) + scroll;
    out.v_TexCoordRipple.z = _136.x;
    out.v_TexCoordRipple.w = _136.y;
    out.v_TexCoordRipple *= g_Scale;
    float rippleTextureAdjustment = g_Texture0Resolution.x / g_Texture0Resolution.y;
    float4 _156 = out.v_TexCoordRipple;
    float2 _158 = _156.xz * rippleTextureAdjustment;
    out.v_TexCoordRipple.x = _158.x;
    out.v_TexCoordRipple.z = _158.y;
    float _164 = out.v_TexCoord.x;
    float _173 = out.v_TexCoord.y;
    float2 _180 = float2((_164 * g_Texture2Resolution.z) / g_Texture2Resolution.x, (_173 * g_Texture2Resolution.w) / g_Texture2Resolution.y);
    out.v_TexCoord.z = _180.x;
    out.v_TexCoord.w = _180.y;
    return out;
}

