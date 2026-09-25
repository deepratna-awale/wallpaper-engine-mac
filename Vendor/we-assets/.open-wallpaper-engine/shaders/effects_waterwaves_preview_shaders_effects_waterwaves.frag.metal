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

fragment main0_out main0(main0_in in [[stage_in]], constant float& g_Time [[buffer(0)]], constant float& g_Speed [[buffer(1)]], constant float& g_Scale [[buffer(2)]], constant float& g_Strength [[buffer(3)]], texture2d<float> g_Texture1 [[texture(0)]], texture2d<float> g_Texture0 [[texture(1)]], sampler g_Texture1Smplr [[sampler(0)]], sampler g_Texture0Smplr [[sampler(1)]])
{
    main0_out out = {};
    float mask = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.zw).x;
    float2 texCoord = in.v_TexCoord.xy;
    float _distance = (g_Time * g_Speed) + (dot(texCoord, in.v_Direction) * g_Scale);
    float2 offset = float2(in.v_Direction.y, -in.v_Direction.x);
    texCoord += ((((offset * sin(_distance)) * g_Strength) * g_Strength) * mask);
    out.out_FragColor = g_Texture0.sample(g_Texture0Smplr, texCoord);
    return out;
}

