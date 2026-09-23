#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 out_FragColor [[color(0)]];
};

struct main0_in
{
    float4 v_TexCoordLeftTop [[user(locn0)]];
    float4 v_TexCoordRightBottom [[user(locn1)]];
};

fragment main0_out main0(main0_in in [[stage_in]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float2 vL = in.v_TexCoordLeftTop.xy;
    float2 vR = in.v_TexCoordRightBottom.xy;
    float2 vT = in.v_TexCoordLeftTop.zw;
    float2 vB = in.v_TexCoordRightBottom.zw;
    float L = g_Texture0.sample(g_Texture0Smplr, vL).y;
    float R = g_Texture0.sample(g_Texture0Smplr, vR).y;
    float T = g_Texture0.sample(g_Texture0Smplr, vT).x;
    float B = g_Texture0.sample(g_Texture0Smplr, vB).x;
    float vorticity = ((R - L) - T) + B;
    out.out_FragColor = float4(0.5 * vorticity, 0.0, 0.0, 1.0);
    return out;
}

