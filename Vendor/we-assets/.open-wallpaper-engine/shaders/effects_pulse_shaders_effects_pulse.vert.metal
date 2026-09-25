#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 v_TexCoord [[user(locn0)]];
    float v_Pulse [[user(locn1)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant float4x4& g_ModelViewProjectionMatrix [[buffer(0)]], constant float2& g_PulseThresholds [[buffer(1)]], constant float& g_Time [[buffer(2)]], constant float& g_PulseSpeed [[buffer(3)]], constant float& g_PulsePhase [[buffer(4)]], constant float& g_PulseAmount [[buffer(5)]])
{
    main0_out out = {};
    out.gl_Position = float4(in.a_Position, 1.0) * g_ModelViewProjectionMatrix;
    out.v_TexCoord = in.a_TexCoord.xyxy;
    out.v_Pulse = smoothstep(g_PulseThresholds.x, g_PulseThresholds.y, (sin((g_Time * g_PulseSpeed) + ((g_PulsePhase - 0.25) * 6.283185482025146484375)) * 0.5) + 0.5) * g_PulseAmount;
    return out;
}

