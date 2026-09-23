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
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    float _37;
    if (A.x == 1.0)
    {
        _37 = A.x;
    }
    else
    {
        _37 = fast::min((B.x * B.x) / (1.0 - A.x), 1.0);
    }
    float _58;
    if (A.y == 1.0)
    {
        _58 = A.y;
    }
    else
    {
        _58 = fast::min((B.y * B.y) / (1.0 - A.y), 1.0);
    }
    float _79;
    if (A.z == 1.0)
    {
        _79 = A.z;
    }
    else
    {
        _79 = fast::min((B.z * B.z) / (1.0 - A.z), 1.0);
    }
    return mix(A, float3(_37, _58, _79), float3(opacity));
}

static inline __attribute__((always_inline))
float3 _max(thread const float& left, thread const float3& right)
{
    return fast::max(float3(left), right);
}

fragment main0_out main0(main0_in in [[stage_in]], constant float& g_NitroLOD [[buffer(0)]], constant float2& g_NitroRanges [[buffer(1)]], constant float3& g_NitroColor0 [[buffer(2)]], constant float3& g_NitroColor1 [[buffer(3)]], constant float& g_NitroAlpha [[buffer(4)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float nitro0 = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoordNitro.xy, level(g_NitroLOD)).x;
    float nitro1 = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoordNitro.zw, level(g_NitroLOD)).x;
    float remap = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.xy).x;
    float2 noiseBase = g_NitroRanges;
    float coreNoise = smoothstep(nitro0, nitro1, 0.100000001490116119384765625 + (remap * 0.800000011920928955078125));
    float nitro = smoothstep(noiseBase.y, noiseBase.x, nitro0 * nitro1) * smoothstep(noiseBase.x, noiseBase.y, nitro0 * nitro1);
    nitro = (coreNoise * nitro) * 4.0;
    float3 nitroColor = mix(g_NitroColor0, g_NitroColor1, float3(nitro));
    float blend = nitro * g_NitroAlpha;
    float3 param = albedo.xyz;
    float3 param_1 = nitroColor;
    float param_2 = blend;
    float3 _205 = ApplyBlending(22, param, param_1, param_2);
    albedo.x = _205.x;
    albedo.y = _205.y;
    albedo.z = _205.z;
    float param_3 = 0.0;
    float3 param_4 = albedo.xyz;
    out.out_FragColor = float4(_max(param_3, param_4), albedo.w);
    return out;
}

