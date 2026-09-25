#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 out_FragColor [[color(0)]];
};

struct main0_in
{
    float2 v_TexCoord [[user(locn0)]];
    float4 v_TexCoordLeftTop [[user(locn1)]];
    float4 v_TexCoordRightBottom [[user(locn2)]];
};

fragment main0_out main0(main0_in in [[stage_in]], texture2d<float> g_Texture1 [[texture(0)]], texture2d<float> g_Texture0 [[texture(1)]], sampler g_Texture1Smplr [[sampler(0)]], sampler g_Texture0Smplr [[sampler(1)]])
{
    main0_out out = {};
    float2 vUv = in.v_TexCoord;
    float2 vL = in.v_TexCoordLeftTop.xy;
    float2 vR = in.v_TexCoordRightBottom.xy;
    float2 vT = in.v_TexCoordLeftTop.zw;
    float2 vB = in.v_TexCoordRightBottom.zw;
    float L = g_Texture1.sample(g_Texture1Smplr, vL).x;
    float R = g_Texture1.sample(g_Texture1Smplr, vR).x;
    float T = g_Texture1.sample(g_Texture1Smplr, vT).x;
    float B = g_Texture1.sample(g_Texture1Smplr, vB).x;
    float C = g_Texture1.sample(g_Texture1Smplr, vUv).x;
    float divergence = g_Texture0.sample(g_Texture0Smplr, vUv).x;
    float pressure = ((((L + R) + B) + T) - divergence) * 0.25;
    out.out_FragColor = float4(pressure, 0.0, 0.0, 1.0);
    return out;
}

