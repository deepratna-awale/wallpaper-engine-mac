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
    float2 v_TexCoord [[user(locn0)]];
    float3 v_TexCoordFx [[user(locn1)]];
};

static inline __attribute__((always_inline))
float3 ApplyBlending(thread const int& mode, thread const float3& base, thread const float3& blend, thread const float& amount)
{
    return mix(base, blend, float3(fast::clamp(amount, 0.0, 1.0)));
}

fragment main0_out main0(main0_in in [[stage_in]], constant float2& g_Feather [[buffer(0)]], constant float2& g_Scale [[buffer(1)]], constant float& g_Time [[buffer(2)]], constant float& g_Speed [[buffer(3)]], constant float& g_Exponent [[buffer(4)]], constant float& g_Smoothness [[buffer(5)]], constant float3& g_ColorRaysEnd [[buffer(6)]], constant float3& g_ColorRaysStart [[buffer(7)]], constant float& g_Intensity [[buffer(8)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float2 fxCoord = in.v_TexCoordFx.xy / float2(in.v_TexCoordFx.z);
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float mask = step(0.0, in.v_TexCoordFx.z);
    float2 fxCoordRef = fxCoord;
    mask *= smoothstep(0.500010013580322265625, 0.5 - g_Feather.x, abs(fxCoord.x - 0.5));
    mask *= smoothstep(0.500010013580322265625, 0.5 - g_Feather.y, abs(fxCoord.y - 0.5));
    float grad = 1.0 - fxCoord.y;
    mask *= grad;
    float2 fxCoord2 = fxCoord;
    fxCoord *= float2(0.0541110001504421234130859375 * g_Scale.x, 0.00311099993996322154998779296875 * g_Scale.y);
    fxCoord2 *= float2(0.07333000004291534423828125 * g_Scale.x, 0.0059671108610928058624267578125 * g_Scale.y);
    fxCoord += (float2(0.0030000000260770320892333984375, 0.000375111005268990993499755859375) * (g_Time * g_Speed));
    fxCoord2 -= (float2(0.004711099900305271148681640625, 0.0007398999878205358982086181640625) * (g_Time * g_Speed));
    float fx0 = g_Texture1.sample(g_Texture1Smplr, fxCoord).x;
    float fx1 = g_Texture1.sample(g_Texture1Smplr, fxCoord2).x;
    float fx = fx0 * fx1;
    fx = powr(fx, g_Exponent);
    fx = smoothstep((1.0 - g_Smoothness) * 0.299989998340606689453125, 0.300000011920928955078125 + (g_Smoothness * 0.699999988079071044921875), fx);
    float3 fxColor = mix(g_ColorRaysEnd, g_ColorRaysStart, float3(fx)) * g_Intensity;
    fx *= mask;
    int param = 31;
    float3 param_1 = albedo.xyz;
    float3 param_2 = fxColor;
    float param_3 = fx;
    float3 _195 = ApplyBlending(param, param_1, param_2, param_3);
    albedo.x = _195.x;
    albedo.y = _195.y;
    albedo.z = _195.z;
    albedo.w = fast::max(albedo.w, fx);
    out.out_FragColor = albedo;
    return out;
}

