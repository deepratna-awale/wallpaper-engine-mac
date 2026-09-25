#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 v_TexCoord [[user(locn0)]];
    float4 v_Cycles [[user(locn1)]];
    float2 v_Blend [[user(locn2)]];
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

vertex main0_out main0(main0_in in [[stage_in]], constant float4x4& g_ModelViewProjectionMatrix [[buffer(0)]], constant float4& g_Texture1Resolution [[buffer(1)]], constant float& g_Time [[buffer(2)]], constant float& g_FlowSpeed [[buffer(3)]], constant float& g_PhaseFeather [[buffer(4)]])
{
    main0_out out = {};
    float4 param = float4(in.a_Position, 1.0);
    float4x4 param_1 = g_ModelViewProjectionMatrix;
    out.gl_Position = mul(param, param_1);
    out.v_TexCoord.x = in.a_TexCoord.x;
    out.v_TexCoord.y = in.a_TexCoord.y;
    float _58 = out.v_TexCoord.x;
    float _70 = out.v_TexCoord.y;
    float2 _78 = float2((_58 * g_Texture1Resolution.z) / g_Texture1Resolution.x, (_70 * g_Texture1Resolution.w) / g_Texture1Resolution.y);
    out.v_TexCoord.z = _78.x;
    out.v_TexCoord.w = _78.y;
    float4 cycles = float4(fract(g_Time * g_FlowSpeed), fract((g_Time * g_FlowSpeed) + 0.5), fract(0.25 + (g_Time * g_FlowSpeed)), fract((0.25 + (g_Time * g_FlowSpeed)) + 0.5));
    float blend = 2.0 * abs(cycles.x - 0.5);
    float blend2 = 2.0 * abs(cycles.z - 0.5);
    float2 smoothParams = float2(0.5 - g_PhaseFeather, 0.5 + g_PhaseFeather);
    blend = smoothstep(smoothParams.x, smoothParams.y, blend);
    blend2 = smoothstep(smoothParams.x, smoothParams.y, blend2);
    out.v_Cycles = cycles - float4(0.5);
    out.v_Blend = float2(blend, blend2);
    return out;
}

