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
    float2 v_ReflectedCoord [[user(locn1)]];
};

static inline __attribute__((always_inline))
float3 ApplyBlending(thread const int& mode, thread const float3& base, thread const float3& blend, thread const float& amount)
{
    return mix(base, blend, float3(fast::clamp(amount, 0.0, 1.0)));
}

fragment main0_out main0(main0_in in [[stage_in]], constant float& g_ReflectionAlpha [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float mask = 1.0;
    float2 reflectedCoord = in.v_ReflectedCoord;
    float4 reflected = g_Texture0.sample(g_Texture0Smplr, reflectedCoord);
    int param = 9;
    float3 param_1 = albedo.xyz;
    float3 param_2 = reflected.xyz;
    float param_3 = mask * g_ReflectionAlpha;
    float3 _69 = ApplyBlending(param, param_1, param_2, param_3);
    out.out_FragColor.x = _69.x;
    out.out_FragColor.y = _69.y;
    out.out_FragColor.z = _69.z;
    out.out_FragColor.w = fast::min(1.0, albedo.w + ((reflected.w * mask) * g_ReflectionAlpha));
    return out;
}

