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
};

fragment main0_out main0(main0_in in [[stage_in]], constant float& g_Brightness [[buffer(0)]], constant float& g_UserAlpha [[buffer(1)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 color = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float4 _24 = color;
    float3 _26 = _24.xyz * g_Brightness;
    color.x = _26.x;
    color.y = _26.y;
    color.z = _26.z;
    color.w *= g_UserAlpha;
    out.out_FragColor = color;
    return out;
}

