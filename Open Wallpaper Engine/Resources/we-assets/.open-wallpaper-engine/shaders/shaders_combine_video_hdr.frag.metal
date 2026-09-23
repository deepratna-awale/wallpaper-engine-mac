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

fragment main0_out main0(main0_in in [[stage_in]], constant float2& g_HDRParams [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float maxHDR = g_HDRParams.y * 2.0;
    float4 _33 = albedo;
    float3 _36 = _33.xyz / float3(maxHDR);
    albedo.x = _36.x;
    albedo.y = _36.y;
    albedo.z = _36.z;
    float4 _45 = albedo;
    float3 _51 = fast::clamp(_45.xyz, float3(0.0), float3(1.0));
    albedo.x = _51.x;
    albedo.y = _51.y;
    albedo.z = _51.z;
    float4 _59 = albedo;
    float3 _61 = _59.xyz * maxHDR;
    albedo.x = _61.x;
    albedo.y = _61.y;
    albedo.z = _61.z;
    out.out_FragColor = albedo;
    return out;
}

