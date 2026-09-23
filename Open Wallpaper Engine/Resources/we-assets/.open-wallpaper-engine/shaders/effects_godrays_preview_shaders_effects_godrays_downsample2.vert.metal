#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 v_TexCoord [[user(locn0)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant float4& g_Texture0Resolution [[buffer(0)]])
{
    main0_out out = {};
    out.gl_Position = float4(in.a_Position, 1.0);
    out.v_TexCoord.x = in.a_TexCoord.x;
    out.v_TexCoord.y = in.a_TexCoord.y;
    float _39 = out.v_TexCoord.x;
    float _51 = out.v_TexCoord.y;
    float2 _59 = float2((_39 * g_Texture0Resolution.z) / g_Texture0Resolution.x, (_51 * g_Texture0Resolution.w) / g_Texture0Resolution.y);
    out.v_TexCoord.z = _59.x;
    out.v_TexCoord.w = _59.y;
    return out;
}

