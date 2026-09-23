#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 out_FragColor [[color(0)]];
};

struct main0_in
{
    float4 v_TexCoord [[user(locn0)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant float& g_Time [[buffer(0)]], constant float& g_FlowSpeed [[buffer(1)]], constant float& g_FlowAmp [[buffer(2)]], texture2d<float> g_Texture2 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], texture2d<float> g_Texture0 [[texture(2)]], sampler g_Texture2Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]], sampler g_Texture0Smplr [[sampler(2)]])
{
    main0_out out = {};
    float flowPhase = (g_Texture2.sample(g_Texture2Smplr, in.v_TexCoord.xy).x - 0.5) * 2.0;
    float2 flowColors = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.zw).xy;
    float2 flowMask = (flowColors - float2(0.5)) * 2.0;
    float2 cycles = float2(fract(g_Time * g_FlowSpeed), fract((g_Time * g_FlowSpeed) + 0.5));
    float blend = 2.0 * abs(cycles.x - 0.5);
    blend = smoothstep(fast::max(0.0, flowPhase), fast::min(1.0, 1.0 + flowPhase), blend);
    float2 flowUVOffset1 = ((flowMask * g_FlowAmp) * 0.100000001490116119384765625) * (cycles.x - 0.5);
    float2 flowUVOffset2 = ((flowMask * g_FlowAmp) * 0.100000001490116119384765625) * (cycles.y - 0.5);
    float4 albedo = mix(g_Texture0.sample(g_Texture0Smplr, (in.v_TexCoord.xy + flowUVOffset1)), g_Texture0.sample(g_Texture0Smplr, (in.v_TexCoord.xy + flowUVOffset2)), float4(blend));
    out.out_FragColor = albedo;
    return out;
}

