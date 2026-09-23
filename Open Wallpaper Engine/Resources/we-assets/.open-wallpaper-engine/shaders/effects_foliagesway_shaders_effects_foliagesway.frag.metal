#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 out_FragColor [[color(0)]];
};

struct main0_in
{
    float4 v_TexCoordNoise [[user(locn0)]];
    float3 v_Params [[user(locn1)]];
    float4 v_TexCoord [[user(locn2)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant float& g_Phase [[buffer(0)]], constant float& g_Speed [[buffer(1)]], constant float& g_Time [[buffer(2)]], constant float& g_Power [[buffer(3)]], texture2d<float> g_Texture2 [[texture(0)]], texture2d<float> g_Texture0 [[texture(1)]], sampler g_Texture2Smplr [[sampler(0)]], sampler g_Texture0Smplr [[sampler(1)]])
{
    main0_out out = {};
    float3 _noise = g_Texture2.sample(g_Texture2Smplr, in.v_TexCoordNoise.xy).xyz;
    float amp = in.v_Params.z;
    float phase = ((((_noise.y * 3.141590118408203125) * 2.0) + (in.v_Params.x * 10.0)) + (in.v_Params.y * 5.0)) * g_Phase;
    float4 sines = float4(phase) + (float4(1.0, -0.16161616146564483642578125, 0.008333300240337848663330078125, -0.00019840999448206275701522827148438) * (g_Speed * g_Time));
    sines = sin(sines);
    float4 csines = float4(0.4000000059604644775390625 + phase) + (float4(-0.5, 0.041666664183139801025390625, -0.001388887991197407245635986328125, 2.4801000108709558844566345214844e-05) * (g_Speed * g_Time));
    csines = sin(csines);
    sines = powr(abs(sines), float4(g_Power)) * sign(sines);
    csines = powr(abs(csines), float4(g_Power)) * sign(csines);
    float2 texCoordOffset;
    texCoordOffset.x = in.v_TexCoordNoise.z * dot(sines, float4(amp));
    texCoordOffset.y = in.v_TexCoordNoise.w * dot(csines, float4(amp));
    out.out_FragColor = g_Texture0.sample(g_Texture0Smplr, (texCoordOffset + in.v_TexCoord.xy));
    return out;
}

