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

fragment main0_out main0(main0_in in [[stage_in]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float2 vUv = in.v_TexCoord;
    float2 vL = in.v_TexCoordLeftTop.xy;
    float2 vR = in.v_TexCoordRightBottom.xy;
    float2 vT = in.v_TexCoordLeftTop.zw;
    float2 vB = in.v_TexCoordRightBottom.zw;
    float L = g_Texture0.sample(g_Texture0Smplr, vL).x;
    float R = g_Texture0.sample(g_Texture0Smplr, vR).x;
    float T = g_Texture0.sample(g_Texture0Smplr, vT).y;
    float B = g_Texture0.sample(g_Texture0Smplr, vB).y;
    float2 C = g_Texture0.sample(g_Texture0Smplr, vUv).xy;
    if (vL.x < 0.0)
    {
        L = -C.x;
    }
    if (vR.x > 1.0)
    {
        R = -C.x;
    }
    if (vT.y > 1.0)
    {
        T = -C.y;
    }
    if (vB.y < 0.0)
    {
        B = -C.y;
    }
    float div = 0.5 * (((R - L) + T) - B);
    out.out_FragColor = float4(div, 0.0, 0.0, 1.0);
    return out;
}

