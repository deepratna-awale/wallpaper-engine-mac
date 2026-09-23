#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 out_FragColor [[color(0)]];
};

struct main0_in
{
    float3 v_TexCoord [[user(locn0)]];
};

fragment main0_out main0(main0_in in [[stage_in]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float2 texCoord = in.v_TexCoord.xy / float2(in.v_TexCoord.z);
    float mask = step(0.0, in.v_TexCoord.z);
    mask *= step(abs(texCoord.x - 0.5), 0.5);
    mask *= step(abs(texCoord.y - 0.5), 0.5);
    out.out_FragColor = g_Texture0.sample(g_Texture0Smplr, texCoord);
    out.out_FragColor.w *= mask;
    return out;
}

