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
    float4 v_TexCoordNitro [[user(locn1)]];
};

static inline __attribute__((always_inline))
float3 ApplyBlending(thread const int& mode, thread const float3& base, thread const float3& blend, thread const float& amount)
{
    return mix(base, blend, float3(fast::clamp(amount, 0.0, 1.0)));
}

fragment main0_out main0(main0_in in [[stage_in]], constant float2& g_NitroRanges [[buffer(0)]], constant float3& g_NitroColor0 [[buffer(1)]], constant float3& g_NitroColor1 [[buffer(2)]], constant float& g_NitroAlpha [[buffer(3)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float nitro0 = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoordNitro.xy).x;
    float nitro1 = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoordNitro.zw).x;
    float remap = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.xy).x;
    float2 noiseBase = g_NitroRanges;
    float coreNoise = smoothstep(nitro0, nitro1, 0.100000001490116119384765625 + (remap * 0.800000011920928955078125));
    float nitro = smoothstep(noiseBase.y, noiseBase.x, nitro0 * nitro1) * smoothstep(noiseBase.x, noiseBase.y, nitro0 * nitro1);
    nitro = (coreNoise * nitro) * 4.0;
    float3 nitroColor = mix(g_NitroColor0, g_NitroColor1, float3(nitro));
    float blend = nitro * g_NitroAlpha;
    int param = 22;
    float3 param_1 = albedo.xyz;
    float3 param_2 = nitroColor;
    float param_3 = blend;
    float3 _127 = ApplyBlending(param, param_1, param_2, param_3);
    albedo.x = _127.x;
    albedo.y = _127.y;
    albedo.z = _127.z;
    out.out_FragColor = albedo;
    return out;
}

