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
    float4 v_TexCoordRipple [[user(locn2)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant float& g_Strength [[buffer(0)]], texture2d<float> g_Texture2 [[texture(0)]], texture2d<float> g_Texture0 [[texture(1)]], sampler g_Texture2Smplr [[sampler(0)]], sampler g_Texture0Smplr [[sampler(1)]])
{
    main0_out out = {};
    float2 texCoord = in.v_TexCoord.xy;
    float mask = 1.0;
    float4 rippleCoords = in.v_TexCoordRipple;
    float3 n1 = (g_Texture2.sample(g_Texture2Smplr, rippleCoords.xy).xyz * 2.0) - float3(1.0);
    float3 n2 = (g_Texture2.sample(g_Texture2Smplr, rippleCoords.zw).xyz * 2.0) - float3(1.0);
    float3 normal = fast::normalize(float3(n1.xy + n2.xy, n1.z));
    texCoord += (((normal.xy * g_Strength) * g_Strength) * mask);
    out.out_FragColor = g_Texture0.sample(g_Texture0Smplr, texCoord);
    return out;
}

