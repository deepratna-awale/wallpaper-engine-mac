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

fragment main0_out main0(main0_in in [[stage_in]], constant float& g_Speed [[buffer(0)]], constant float& g_Time [[buffer(1)]], constant float& g_Power [[buffer(2)]], constant float& g_Amp [[buffer(3)]], texture2d<float> g_Texture2 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], texture2d<float> g_Texture0 [[texture(2)]], sampler g_Texture2Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]], sampler g_Texture0Smplr [[sampler(2)]])
{
    main0_out out = {};
    float flowPhase = g_Texture2.sample(g_Texture2Smplr, in.v_TexCoord.zw).x * 6.280000209808349609375;
    float2 flowColors = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.zw).xy;
    float2 flowMask = (flowColors - float2(0.4979999959468841552734375)) * 2.0;
    float offset = sin((g_Speed * g_Time) + flowPhase);
    offset = powr(abs(offset), g_Power) * sign(offset);
    float2 texCoord = in.v_TexCoord.xy + (((flowMask * offset) * g_Amp) * g_Amp);
    out.out_FragColor = g_Texture0.sample(g_Texture0Smplr, texCoord);
    return out;
}

