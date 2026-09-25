#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float2 v_TexCoord [[user(locn0)]];
    float4 v_ViewRect [[user(locn1)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant float4x4& g_ModelMatrix [[buffer(0)]])
{
    main0_out out = {};
    out.gl_Position = float4(in.a_Position, 1.0);
    out.v_TexCoord.x = mix(g_ModelMatrix[1].x, g_ModelMatrix[1].z, in.a_TexCoord.x);
    out.v_TexCoord.y = mix(g_ModelMatrix[1].w, g_ModelMatrix[1].y, in.a_TexCoord.y);
    out.v_ViewRect = g_ModelMatrix[0];
    return out;
}

