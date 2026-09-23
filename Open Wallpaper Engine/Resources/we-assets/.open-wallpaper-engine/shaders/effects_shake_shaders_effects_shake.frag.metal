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
    float2 v_Bounds [[user(locn1)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant float& g_Speed [[buffer(0)]], constant float& g_Time [[buffer(1)]], constant float2& g_Friction [[buffer(2)]], constant float& g_Amp [[buffer(3)]], texture2d<float> g_Texture1 [[texture(0)]], texture2d<float> g_Texture0 [[texture(1)]], sampler g_Texture1Smplr [[sampler(0)]], sampler g_Texture0Smplr [[sampler(1)]])
{
    main0_out out = {};
    float flowPhase = 0.0;
    float2 flowColors = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.zw).xy;
    float2 flowMask = (flowColors - float2(0.4979999959468841552734375)) * 2.0;
    float offset = 0.0;
    float time = (g_Speed * g_Time) + flowPhase;
    offset = sin(fract(time / 6.283185482025146484375) * 6.283185482025146484375);
    offset = (offset * 0.4979999959468841552734375) + 0.5;
    float base = step(0.0, cos(time));
    offset = mix(1.0 - powr(1.0 - offset, g_Friction.x), powr(offset, g_Friction.y), base);
    offset = fast::clamp((offset - in.v_Bounds.x) * in.v_Bounds.y, 0.0, 1.0);
    offset = (offset * 2.0) - 1.0;
    float2 texCoordOffset = flowMask * ((offset * g_Amp) * g_Amp);
    out.out_FragColor = g_Texture0.sample(g_Texture0Smplr, (texCoordOffset + in.v_TexCoord.xy));
    return out;
}

