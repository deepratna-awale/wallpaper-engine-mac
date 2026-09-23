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

vertex main0_out main0(main0_in in [[stage_in]], constant float4x4& g_ModelViewProjectionMatrix [[buffer(0)]], constant float4& g_Texture0Resolution [[buffer(1)]], constant float& g_Time [[buffer(2)]], constant float& g_NoiseScale [[buffer(3)]], constant float& g_Chromatic [[buffer(4)]])
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
    float2 _107 = out.v_TexCoordNoise.xy * float2(0.100000001490116119384765625, 10.0);
    out.v_TexCoordVHSNoise.x = _107.x;
    out.v_TexCoordVHSNoise.y = _107.y;
    float2 _117 = out.v_TexCoordNoise.zw * float2(0.00999999977648258209228515625, 2.0);
    out.v_TexCoordVHSNoise.z = _117.x;
    out.v_TexCoordVHSNoise.w = _117.y;
    out.v_TexCoordGlitch = out.v_TexCoord.xyxy;
    float chromatic = fast::min(g_Chromatic, 0.100000001490116119384765625);
    float3 glitchOffset = (smoothstep(float3(0.0), float3(2.0), float3(1.0) + (sin((float3(11.0, 7.0, 13.0) * g_Time) * 2.0) * 0.5)) * chromatic) * float3(0.0019000000320374965667724609375, 0.00209999992512166500091552734375, 0.001700000022538006305694580078125);
    out.v_TexCoordGlitch.y += ((0.0040000001899898052215576171875 * chromatic) + glitchOffset.x);
    float4 _172 = out.v_TexCoordGlitch;
    float2 _174 = _172.xz + (glitchOffset.xy + (float2(0.004999999888241291046142578125, -0.0005000000237487256526947021484375) * chromatic));
    out.v_TexCoordGlitch.x = _174.x;
    out.v_TexCoordGlitch.z = _174.y;
    out.v_TexCoordGlitch.z -= (glitchOffset.z + (0.006000000052154064178466796875 * chromatic));
    out.v_TexCoordGlitch.w -= (0.00449999980628490447998046875 * chromatic);
    return out;
}

