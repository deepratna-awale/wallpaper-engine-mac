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
    float2 v_Direction [[user(locn1)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant float& g_Time [[buffer(0)]], constant float& g_Speed [[buffer(1)]], constant float& g_Scale [[buffer(2)]], constant float& g_Strength [[buffer(3)]], constant float& g_Exponent [[buffer(4)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float mask = 1.0;
    float2 texCoord = in.v_TexCoord.xy;
    float2 texCoordMotion = texCoord;
    float pos = abs(dot(texCoordMotion - float2(0.5), in.v_Direction));
    float _distance = (g_Time * g_Speed) + (dot(texCoordMotion, in.v_Direction) * g_Scale);
    float strength = g_Strength * g_Strength;
    float2 offset = float2(in.v_Direction.y, -in.v_Direction.x);
    float val1 = sin(_distance);
    float s1 = sign(val1);
    val1 = powr(abs(val1), g_Exponent);
    texCoord += (((offset * (val1 * s1)) * strength) * mask);
    out.out_FragColor = g_Texture0.sample(g_Texture0Smplr, texCoord);
    return out;
}

