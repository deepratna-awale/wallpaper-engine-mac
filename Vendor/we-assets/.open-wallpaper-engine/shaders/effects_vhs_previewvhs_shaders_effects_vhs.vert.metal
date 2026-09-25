#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 v_TexCoord [[user(locn0)]];
    float4 v_TexCoordGlitch [[user(locn1)]];
    float4 v_TexCoordNoise [[user(locn2)]];
    float4 v_TexCoordVHSNoise [[user(locn3)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

static inline __attribute__((always_inline))
float4 mul(thread const float4& value, thread const float4x4& matrix)
{
    return matrix * value;
}

vertex main0_out main0(main0_in in [[stage_in]], constant float4x4& g_ModelViewProjectionMatrix [[buffer(0)]], constant float4& g_Texture0Resolution [[buffer(1)]], constant float& g_Time [[buffer(2)]], constant float& g_NoiseScale [[buffer(3)]], constant float& g_ArtifactsScale [[buffer(4)]], constant float& g_Chromatic [[buffer(5)]], constant float& g_NoiseAlpha [[buffer(6)]])
{
    main0_out out = {};
    float4 param = float4(in.a_Position, 1.0);
    float4x4 param_1 = g_ModelViewProjectionMatrix;
    out.gl_Position = mul(param, param_1);
    float aspect = g_Texture0Resolution.z / g_Texture0Resolution.w;
    float t = fract(g_Time);
    out.v_TexCoord = in.a_TexCoord.xyxy;
    float2 _75 = (in.a_TexCoord + float2(t)) * g_NoiseScale;
    out.v_TexCoordNoise.x = _75.x;
    out.v_TexCoordNoise.y = _75.y;
    float2 _91 = ((in.a_TexCoord - float2(t * 2.5)) * g_NoiseScale) * 0.519999980926513671875;
    out.v_TexCoordNoise.z = _91.x;
    out.v_TexCoordNoise.w = _91.y;
    out.v_TexCoordNoise *= float4(aspect, 1.0, aspect, 1.0);
    float2 _110 = (out.v_TexCoordNoise.xy * float2(0.100000001490116119384765625, 10.0)) * g_ArtifactsScale;
    out.v_TexCoordVHSNoise.x = _110.x;
    out.v_TexCoordVHSNoise.y = _110.y;
    float2 _122 = (out.v_TexCoordNoise.zw * float2(0.00999999977648258209228515625, 2.0)) * g_ArtifactsScale;
    out.v_TexCoordVHSNoise.z = _122.x;
    out.v_TexCoordVHSNoise.w = _122.y;
    out.v_TexCoordGlitch = out.v_TexCoord.xyxy;
    float3 glitchOffset = (smoothstep(float3(0.0), float3(2.0), float3(1.0) + (sin((float3(11.0, 7.0, 13.0) * g_Time) * 2.0) * 0.5)) * g_Chromatic) * float3(0.007000000216066837310791015625, 0.008000000379979610443115234375, 0.0074999998323619365692138671875);
    out.v_TexCoordGlitch.y += ((0.0040000001899898052215576171875 * g_Chromatic) + glitchOffset.x);
    float4 _174 = out.v_TexCoordGlitch;
    float2 _176 = _174.xz + (glitchOffset.xy + (float2(0.004999999888241291046142578125, -0.0005000000237487256526947021484375) * g_Chromatic));
    out.v_TexCoordGlitch.x = _176.x;
    out.v_TexCoordGlitch.z = _176.y;
    out.v_TexCoordGlitch.z -= (glitchOffset.z + (0.006000000052154064178466796875 * g_Chromatic));
    out.v_TexCoordGlitch.w -= (0.00449999980628490447998046875 * g_Chromatic);
    out.v_TexCoord.x += (glitchOffset.z * fast::min(1.0, g_NoiseAlpha));
    out.v_TexCoord.y -= (glitchOffset.z * fast::min(1.0, g_NoiseAlpha));
    return out;
}

