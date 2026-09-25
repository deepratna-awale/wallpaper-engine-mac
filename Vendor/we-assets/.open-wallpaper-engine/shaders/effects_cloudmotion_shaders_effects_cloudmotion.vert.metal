#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 v_TexCoord [[user(locn0)]];
    float2 v_NoiseCoord [[user(locn1)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant float4x4& g_ModelViewProjectionMatrix [[buffer(0)]], constant float4& g_Texture0Resolution [[buffer(1)]], constant float& u_scale [[buffer(2)]], constant float& u_scaleX [[buffer(3)]], constant float& g_Time [[buffer(4)]], constant float& u_speed [[buffer(5)]])
{
    main0_out out = {};
    out.gl_Position = float4(in.a_Position, 1.0) * g_ModelViewProjectionMatrix;
    out.v_TexCoord = in.a_TexCoord.xyxy;
    out.v_NoiseCoord = out.v_TexCoord.xy;
    out.v_NoiseCoord.x *= (g_Texture0Resolution.x / g_Texture0Resolution.y);
    out.v_NoiseCoord *= u_scale;
    out.v_NoiseCoord.x *= u_scaleX;
    out.v_NoiseCoord.x += (g_Time * u_speed);
    return out;
}

