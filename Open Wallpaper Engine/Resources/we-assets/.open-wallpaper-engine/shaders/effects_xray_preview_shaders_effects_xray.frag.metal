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
    float3 v_PointerUV [[user(locn1)]];
};

static inline __attribute__((always_inline))
float3 ApplyBlending(thread const int& mode, thread const float3& base, thread const float3& blend, thread const float& amount)
{
    return mix(base, blend, float3(fast::clamp(amount, 0.0, 1.0)));
}

fragment main0_out main0(main0_in in [[stage_in]], constant float& g_Multiply [[buffer(0)]], constant float& g_PointerScale [[buffer(1)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], texture2d<float> g_Texture2 [[texture(2)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]], sampler g_Texture2Smplr [[sampler(2)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float4 mask = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.zw);
    float blend = mask.w * g_Multiply;
    float2 unprojectedUVs = in.v_PointerUV.xy / float2(in.v_PointerUV.z);
    float2 texS = in.v_TexCoord.xy;
    texS.y = 1.0 - texS.y;
    unprojectedUVs = texS - unprojectedUVs;
    unprojectedUVs = fast::clamp(unprojectedUVs, float2(0.0), float2(1.0));
    unprojectedUVs -= float2(0.5);
    unprojectedUVs *= g_PointerScale;
    unprojectedUVs += float2(0.5);
    float2 blendSample = g_Texture2.sample(g_Texture2Smplr, unprojectedUVs).xw;
    blend *= (blendSample.x * blendSample.y);
    int param = 0;
    float3 param_1 = albedo.xyz;
    float3 param_2 = mask.xyz;
    float param_3 = blend;
    float3 _120 = ApplyBlending(param, param_1, param_2, param_3);
    albedo.x = _120.x;
    albedo.y = _120.y;
    albedo.z = _120.z;
    out.out_FragColor = albedo;
    return out;
}

