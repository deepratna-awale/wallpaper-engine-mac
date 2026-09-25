#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float2 v_TexCoord [[user(locn0)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant float4x4& g_ModelViewProjectionMatrix [[buffer(0)]], constant float& g_Top [[buffer(1)]], constant float& g_Bottom [[buffer(2)]], constant float& g_Left [[buffer(3)]], constant float& g_Right [[buffer(4)]])
{
    main0_out out = {};
    float3 position = in.a_Position;
    out.gl_Position = float4(position, 1.0) * g_ModelViewProjectionMatrix;
    out.v_TexCoord = in.a_TexCoord;
    out.v_TexCoord.x -= ((step(in.a_TexCoord.y, 0.5) * g_Top) + (step(0.5, in.a_TexCoord.y) * g_Bottom));
    out.v_TexCoord.y += ((step(in.a_TexCoord.x, 0.5) * g_Left) + (step(0.5, in.a_TexCoord.x) * g_Right));
    return out;
}

