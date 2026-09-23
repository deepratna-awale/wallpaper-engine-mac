#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float3 v_TexCoord [[user(locn0)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant float& u_Pressure [[buffer(0)]], constant float& g_Frametime [[buffer(1)]])
{
    main0_out out = {};
    out.gl_Position = float4(in.a_Position, 1.0);
    out.v_TexCoord.x = in.a_TexCoord.x;
    out.v_TexCoord.y = in.a_TexCoord.y;
    out.v_TexCoord.z = powr(u_Pressure, 60.0 * g_Frametime);
    return out;
}

