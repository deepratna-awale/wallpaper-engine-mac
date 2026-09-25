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
    float3 v_ScreenCoord [[user(locn1)]];
};

fragment main0_out main0(main0_in in [[stage_in]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float4 result = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float2 screenCoord = ((in.v_ScreenCoord.xy / float2(in.v_ScreenCoord.z)) * float2(0.5)) + float2(0.5);
    float4 bg = g_Texture1.sample(g_Texture1Smplr, screenCoord);
    float3 _55 = mix(bg.xyz, result.xyz, float3(result.w));
    out.out_FragColor.x = _55.x;
    out.out_FragColor.y = _55.y;
    out.out_FragColor.z = _55.z;
    out.out_FragColor.w = 1.0;
    return out;
}

