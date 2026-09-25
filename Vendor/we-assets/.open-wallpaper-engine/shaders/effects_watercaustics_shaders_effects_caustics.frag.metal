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
float3 ApplyBlending(thread const int& mode, thread const float3& base, thread const float3& blend, thread const float& amount)
{
    return mix(base, blend, float3(fast::clamp(amount, 0.0, 1.0)));
}

fragment main0_out main0(main0_in in [[stage_in]], constant float4& g_Texture0Resolution [[buffer(0)]], constant float& u_scale [[buffer(1)]], constant float& g_Time [[buffer(2)]], constant float& u_speed [[buffer(3)]], constant float& u_timeoffset [[buffer(4)]], constant float& u_distortion [[buffer(5)]], constant float& u_chromatic [[buffer(6)]], constant float& u_blur [[buffer(7)]], constant float& u_glow [[buffer(8)]], constant float& u_brightness [[buffer(9)]], constant float3& u_color1 [[buffer(10)]], constant float3& u_color2 [[buffer(11)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture4 [[texture(1)]], texture2d<float> g_Texture3 [[texture(2)]], texture2d<float> g_Texture2 [[texture(3)]], texture2d<float> g_Texture5 [[texture(4)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture4Smplr [[sampler(1)]], sampler g_Texture3Smplr [[sampler(2)]], sampler g_Texture2Smplr [[sampler(3)]], sampler g_Texture5Smplr [[sampler(4)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float mask = 1.0;
    float ratio = g_Texture0Resolution.x / g_Texture0Resolution.y;
    float2 causticsCoords = in.v_TexCoord.xy;
    causticsCoords.x *= ratio;
    causticsCoords *= u_scale;
    float2 noiseCoords = causticsCoords;
    float2 noiseCoords2 = causticsCoords;
    float2 blendCoords = causticsCoords;
    float2 shiftCoords = causticsCoords;
    noiseCoords *= 0.0199999995529651641845703125;
    noiseCoords2 *= 0.0333000011742115020751953125;
    blendCoords *= 0.013330000452697277069091796875;
    shiftCoords *= 0.0500000007450580596923828125;
    float time = (g_Time * u_speed) + u_timeoffset;
    noiseCoords.x += (time * 0.004999999888241291046142578125);
    noiseCoords2.y += (time * 0.0041109998710453510284423828125);
    blendCoords += float2(time * 0.00377699988894164562225341796875);
    shiftCoords += float2(time * 0.00999999977648258209228515625);
    float4 shiftColor = (g_Texture4.sample(g_Texture4Smplr, shiftCoords) * 2.0) - float4(1.0);
    float4 noiseColor = (g_Texture3.sample(g_Texture3Smplr, noiseCoords) * 2.0) - float4(1.0);
    float4 noiseColor2 = (g_Texture3.sample(g_Texture3Smplr, noiseCoords2) * 2.0) - float4(1.0);
    causticsCoords += ((noiseColor.xy * 0.02500000037252902984619140625) * u_distortion);
    causticsCoords += ((noiseColor2.xy * 0.02500000037252902984619140625) * u_distortion);
    causticsCoords += (shiftColor.xy * u_distortion);
    float2 causticsCoordsLeft = causticsCoords;
    float2 causticsCoordsRight = causticsCoords;
    causticsCoordsLeft.x -= (0.00999999977648258209228515625 * u_chromatic);
    causticsCoordsRight.x += (0.00999999977648258209228515625 * u_chromatic);
    float3 caustics = float3(g_Texture2.sample(g_Texture2Smplr, causticsCoordsLeft).x, g_Texture2.sample(g_Texture2Smplr, causticsCoords).x, g_Texture2.sample(g_Texture2Smplr, causticsCoordsRight).x);
    float glowSample = g_Texture5.sample(g_Texture5Smplr, causticsCoords).x;
    float4 blendColor = g_Texture3.sample(g_Texture3Smplr, blendCoords);
    caustics = mix(caustics, float3(glowSample), float3(u_blur));
    float causticsSample = dot(caustics, float3(0.3333300054073333740234375));
    causticsSample = smoothstep(blendColor.x * 0.800000011920928955078125, 1.0 - (blendColor.y * 0.20000000298023223876953125), causticsSample + (glowSample * u_glow));
    float3 causticsColor = mix(u_color1, u_color2, float3(blendColor.x)) * u_brightness;
    causticsColor *= caustics;
    int param = 32;
    float3 param_1 = albedo.xyz;
    float3 param_2 = causticsColor;
    float param_3 = mask * causticsSample;
    float3 _267 = ApplyBlending(param, param_1, param_2, param_3);
    albedo.x = _267.x;
    albedo.y = _267.y;
    albedo.z = _267.z;
    out.out_FragColor = albedo;
    return out;
}

