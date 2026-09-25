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
    float4 v_TexCoord [[user(locn0)]];
    float3 v_RefracttTexCoord [[user(locn1)]];
};

static inline __attribute__((always_inline))
float3 DecompressNormal(thread float4& normal)
{
    float4 _15 = normal;
    float2 _21 = (_15.wy * 2.0) - float2(1.0);
    normal.x = _21.x;
    normal.y = _21.y;
    normal.z = sqrt(fast::clamp((1.0 - (normal.x * normal.x)) - (normal.y * normal.y), 0.0, 1.0));
    return normal.xyz;
}

fragment main0_out main0(main0_in in [[stage_in]], texture2d<float> g_Texture1 [[texture(0)]], texture2d<float> g_Texture0 [[texture(1)]], sampler g_Texture1Smplr [[sampler(0)]], sampler g_Texture0Smplr [[sampler(1)]])
{
    main0_out out = {};
    float mask = 1.0;
    float2 texCoord = in.v_TexCoord.xy;
    float4 param = g_Texture1.sample(g_Texture1Smplr, in.v_RefracttTexCoord.xy);
    float3 _71 = DecompressNormal(param);
    float3 normal = _71;
    texCoord += ((normal.xy * in.v_RefracttTexCoord.z) * mask);
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, texCoord);
    out.out_FragColor = albedo;
    return out;
}

