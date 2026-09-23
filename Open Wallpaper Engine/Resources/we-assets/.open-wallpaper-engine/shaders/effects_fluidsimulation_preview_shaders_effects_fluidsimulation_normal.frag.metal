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

fragment main0_out main0(main0_in in [[stage_in]], constant float4& g_Texture0Resolution [[buffer(0)]], constant float& u_Depth [[buffer(1)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float2 fxCoords = in.v_TexCoord;
    float refAlpha = g_Texture0.sample(g_Texture0Smplr, fxCoords).w;
    float2 ist = float2(1.0) / g_Texture0Resolution.xy;
    float s10 = g_Texture0.sample(g_Texture0Smplr, (fxCoords + float2(ist.x, 0.0))).w;
    float s01 = g_Texture0.sample(g_Texture0Smplr, (fxCoords + float2(0.0, ist.y))).w;
    float2 base = float2(s10 - refAlpha, s01 - refAlpha) * float2(25.0 * u_Depth);
    base = fast::clamp(base, float2(-1.0), float2(1.0)) * refAlpha;
    float3 normal = float3(base, 0.0);
    normal.x = -normal.x;
    normal.z = sqrt(fast::clamp((1.0 - (normal.x * normal.x)) - (normal.y * normal.y), 0.0, 1.0));
    out.out_FragColor = float4((normal * float3(0.5)) + float3(0.5), 1.0);
    return out;
}

