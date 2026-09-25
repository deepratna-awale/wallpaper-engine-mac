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

fragment main0_out main0(main0_in in [[stage_in]], constant float& g_Brightness [[buffer(0)]], constant float& g_UserAlpha [[buffer(1)]], constant float& g_Power [[buffer(2)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float4 _24 = albedo;
    float3 _26 = _24.xyz * g_Brightness;
    albedo.x = _26.x;
    albedo.y = _26.y;
    albedo.z = _26.z;
    albedo.w *= g_UserAlpha;
    float4 _45 = albedo;
    float3 _50 = powr(_45.xyz, float3(g_Power));
    albedo.x = _50.x;
    albedo.y = _50.y;
    albedo.z = _50.z;
    out.out_FragColor = albedo;
    return out;
}

