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

vertex main0_out main0(main0_in in [[stage_in]], constant float4x4& g_ModelViewProjectionMatrix [[buffer(0)]])
{
    main0_out out = {};
    float3 position = in.a_Position;
    float3 localPos = position;
    out.v_TexCoord = in.a_TexCoord;
    out.gl_Position = float4(localPos, 1.0) * g_ModelViewProjectionMatrix;
    return out;
}

