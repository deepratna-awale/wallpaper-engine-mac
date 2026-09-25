#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 out_FragColor [[color(0)]];
};

struct main0_in
{
    float4 v_TexCoord01 [[user(locn0)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant float3& g_ColorRays [[buffer(0)]], constant float& g_Intensity [[buffer(1)]])
{
    main0_out out = {};
    float2 texCoords = in.v_TexCoord01.xy;
    float4 albedo = float4(0.0);
    float4 _23 = albedo;
    float3 _25 = _23.xyz * g_ColorRays;
    albedo.x = _25.x;
    albedo.y = _25.y;
    albedo.z = _25.z;
    out.out_FragColor = float4(albedo.xyz * (g_Intensity * 0.375), fast::clamp((g_Intensity * 0.375) * albedo.w, 0.0, 1.0));
    return out;
}

