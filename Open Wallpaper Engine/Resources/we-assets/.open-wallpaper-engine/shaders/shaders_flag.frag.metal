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
    float4 v_NormalCoord [[user(locn1)]];
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

fragment main0_out main0(main0_in in [[stage_in]], constant float& g_WaveStrength [[buffer(0)]], texture2d<float> g_Texture1 [[texture(0)]], texture2d<float> g_Texture0 [[texture(1)]], texture2d<float> g_Texture2 [[texture(2)]], sampler g_Texture1Smplr [[sampler(0)]], sampler g_Texture0Smplr [[sampler(1)]], sampler g_Texture2Smplr [[sampler(2)]])
{
    main0_out out = {};
    float2 normalCoords1 = in.v_NormalCoord.xy;
    float2 normalCoords2 = in.v_NormalCoord.zw;
    normalCoords1.x -= (((0.5 - in.v_TexCoord.x) * (1.0 - in.v_TexCoord.y)) * 3.0);
    normalCoords1.x += ((2.0 * powr(in.v_TexCoord.y - 0.100000001490116119384765625, 3.0)) * powr(in.v_TexCoord.x, 2.0));
    normalCoords2.x -= (((1.0 - in.v_TexCoord.x) * (1.0 - in.v_TexCoord.y)) * 2.0);
    float4 param = g_Texture1.sample(g_Texture1Smplr, normalCoords1);
    float3 _113 = DecompressNormal(param);
    float3 normal = _113;
    float4 param_1 = g_Texture1.sample(g_Texture1Smplr, normalCoords2);
    float3 _118 = DecompressNormal(param_1);
    normal *= _118;
    normal = mix(float3(0.0, 0.0, 1.0), normal, float3(g_WaveStrength));
    normal = fast::normalize(normal);
    float2 baseCoords = in.v_TexCoord + (normal.xy * 0.0199999995529651641845703125);
    float3 albedo = g_Texture0.sample(g_Texture0Smplr, baseCoords).xyz;
    float cloth = g_Texture2.sample(g_Texture2Smplr, (baseCoords * 4.0)).x;
    float3 color = albedo;
    float light = (0.20000000298023223876953125 + (dot(float3(0.7070000171661376953125, 0.7070000171661376953125, 0.0), normal) * 0.5)) + 0.5;
    light += (powr(light, 5.0) * 0.5);
    color *= (light + (light * fast::clamp((cloth * 2.0) - 1.0, 0.0, 1.0)));
    out.out_FragColor.x = color.x;
    out.out_FragColor.y = color.y;
    out.out_FragColor.z = color.z;
    out.out_FragColor.w = 1.0;
    return out;
}

