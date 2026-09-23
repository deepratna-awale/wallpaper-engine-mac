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
};

static inline __attribute__((always_inline))
float2 rotateVec2(thread const float4& value, thread const float& angle)
{
    float s = sin(angle);
    float c = cos(angle);
    return float2((value.x * c) - (value.y * s), (value.x * s) + (value.y * c));
}

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return mix(A, A + (A * B), float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant float& u_direction [[buffer(0)]], constant float& u_scale [[buffer(1)]], constant float& u_offset [[buffer(2)]], constant float& u_speed [[buffer(3)]], constant float& g_Time [[buffer(4)]], constant float& u_delay [[buffer(5)]], constant float3& u_color [[buffer(6)]], constant float& u_amount [[buffer(7)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture3 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture3Smplr [[sampler(1)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float mask = 1.0;
    float offset = 0.0;
    float4 param = in.v_TexCoord;
    float param_1 = (-u_direction) + 1.57079637050628662109375;
    float2 shimmerCoord = rotateVec2(param, param_1) * u_scale;
    shimmerCoord.x += (u_offset + (u_speed * (g_Time + offset)));
    shimmerCoord.x = fast::clamp((fract(shimmerCoord.x / (u_scale * u_delay)) * u_scale) * u_delay, 0.0, 1.0);
    float3 shimmerColor = g_Texture3.sample(g_Texture3Smplr, fract(shimmerCoord)).xyz;
    float3 effectAlbedo = shimmerColor * u_color;
    float3 param_2 = albedo.xyz;
    float3 param_3 = effectAlbedo;
    float param_4 = 1.0;
    effectAlbedo = ApplyBlending(32, param_2, param_3, param_4);
    float4 _152 = albedo;
    float3 _161 = mix(_152.xyz, effectAlbedo, (shimmerColor * mask) * u_amount);
    albedo.x = _161.x;
    albedo.y = _161.y;
    albedo.z = _161.z;
    out.out_FragColor = albedo;
    return out;
}

