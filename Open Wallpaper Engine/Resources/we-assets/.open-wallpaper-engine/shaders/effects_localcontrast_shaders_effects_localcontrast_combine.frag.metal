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
};

fragment main0_out main0(main0_in in [[stage_in]], constant float& g_Amount [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture2 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture2Smplr [[sampler(1)]])
{
    main0_out out = {};
    float2 blurredCoords = in.v_TexCoord.xy;
    float4 blurred = g_Texture0.sample(g_Texture0Smplr, blurredCoords);
    float4 albedo = g_Texture2.sample(g_Texture2Smplr, in.v_TexCoord.xy);
    float3 delta = albedo.xyz - blurred.xyz;
    float3 enhanced = albedo.xyz + (delta * g_Amount);
    float mask = 1.0;
    float4 _50 = albedo;
    float3 _55 = mix(_50.xyz, enhanced, float3(mask));
    albedo.x = _55.x;
    albedo.y = _55.y;
    albedo.z = _55.z;
    out.out_FragColor = albedo;
    return out;
}

