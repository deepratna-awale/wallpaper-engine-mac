#pragma clang diagnostic ignored "-Wmissing-prototypes"

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
    float4 v_Color [[user(locn1)]];
};

static inline __attribute__((always_inline))
float4 ConvertTexture0Format(thread const float4& _sample)
{
    return _sample;
}

fragment main0_out main0(main0_in in [[stage_in]], constant float& g_Overbright [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 param = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float4 color = in.v_Color * ConvertTexture0Format(param);
    float4 _37 = color;
    float3 _39 = _37.xyz * g_Overbright;
    color.x = _39.x;
    color.y = _39.y;
    color.z = _39.z;
    out.out_FragColor = color;
    return out;
}

