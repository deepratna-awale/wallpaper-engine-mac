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
    float2 v_NoiseCoord [[user(locn1)]];
};

static inline __attribute__((always_inline))
float2 rotateVec2(thread const float2& value, thread const float& angle)
{
    float s = sin(angle);
    float c = cos(angle);
    return float2((value.x * c) - (value.y * s), (value.x * s) + (value.y * c));
}

fragment main0_out main0(main0_in in [[stage_in]], constant float& u_amount [[buffer(0)]], constant float& u_direction [[buffer(1)]], texture2d<float> g_Texture2 [[texture(0)]], texture2d<float> g_Texture0 [[texture(1)]], sampler g_Texture2Smplr [[sampler(0)]], sampler g_Texture0Smplr [[sampler(1)]])
{
    main0_out out = {};
    float mask = 1.0;
    float3 _noise = g_Texture2.sample(g_Texture2Smplr, in.v_NoiseCoord).xyz;
    float2 uvs = in.v_TexCoord.xy;
    float2 offset = float2((((_noise.x * 2.0) - 1.0) * u_amount) * mask, 0.0);
    float2 param = offset;
    float param_1 = u_direction + 1.57079637050628662109375;
    offset = rotateVec2(param, param_1);
    uvs += offset;
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, uvs);
    out.out_FragColor = albedo;
    return out;
}

