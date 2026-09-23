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
    float4 v_Cycles [[user(locn2)]];
    float2 v_Blend [[user(locn3)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant float& g_FlowPhaseScale [[buffer(0)]], constant float& g_FlowAmp [[buffer(1)]], texture2d<float> g_Texture2 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], texture2d<float> g_Texture0 [[texture(2)]], sampler g_Texture2Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]], sampler g_Texture0Smplr [[sampler(2)]])
{
    main0_out out = {};
    float flowPhase = g_Texture2.sample(g_Texture2Smplr, (in.v_TexCoord.xy * g_FlowPhaseScale)).x;
    float2 flowColors = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.zw).xy;
    float2 flowMask = (flowColors - float2(0.4979999959468841552734375)) * 2.0;
    float flowAmount = length(flowMask);
    float4 flowUVOffset = ((flowMask.xyxy * g_FlowAmp) * 0.100000001490116119384765625) * in.v_Cycles.xxyy;
    float4 flowUVOffset2 = ((flowMask.xyxy * g_FlowAmp) * 0.100000001490116119384765625) * in.v_Cycles.zzww;
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float4 flowAlbedo = mix(g_Texture0.sample(g_Texture0Smplr, (in.v_TexCoord.xy + flowUVOffset.xy)), g_Texture0.sample(g_Texture0Smplr, (in.v_TexCoord.xy + flowUVOffset.zw)), float4(in.v_Blend.x));
    float4 flowAlbedo2 = mix(g_Texture0.sample(g_Texture0Smplr, (in.v_TexCoord.xy + flowUVOffset2.xy)), g_Texture0.sample(g_Texture0Smplr, (in.v_TexCoord.xy + flowUVOffset2.zw)), float4(in.v_Blend.y));
    flowAlbedo = mix(flowAlbedo, flowAlbedo2, float4(smoothstep(0.20000000298023223876953125, 0.800000011920928955078125, flowPhase)));
    out.out_FragColor = mix(albedo, flowAlbedo, float4(flowAmount));
    return out;
}

