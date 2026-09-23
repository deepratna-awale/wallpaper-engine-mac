#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float2 v_TexCoord [[user(locn0)]];
    float3 v_ScreenCoord [[user(locn1)]];
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

vertex main0_out main0(main0_in in [[stage_in]], constant float4x4& g_ModelViewProjectionMatrix [[buffer(0)]])
{
    main0_out out = {};
    float4 param = float4(in.a_Position, 1.0);
    float4x4 param_1 = g_ModelViewProjectionMatrix;
    out.v_ScreenCoord = mul(param, param_1).xyw;
    float3 position = float3(in.a_TexCoord, 0.0);
    float3 _49 = position;
    float2 _54 = (_49.xy * 2.0) - float2(1.0);
    position.x = _54.x;
    position.y = _54.y;
    out.gl_Position = float4(position, 1.0);
    out.v_TexCoord = in.a_TexCoord;
    return out;
}

