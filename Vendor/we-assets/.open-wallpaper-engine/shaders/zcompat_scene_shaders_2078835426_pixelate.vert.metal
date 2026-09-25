#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float2 v_PixelCoord [[user(locn0)]];
    float4 v_PixelSize [[user(locn1)]];
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

vertex main0_out main0(main0_in in [[stage_in]], constant float4x4& g_ModelViewProjectionMatrix [[buffer(0)]], constant float2& u_NewResolution [[buffer(1)]], constant float4& g_Texture0Resolution [[buffer(2)]])
{
    main0_out out = {};
    float4 param = float4(in.a_Position, 1.0);
    float4x4 param_1 = g_ModelViewProjectionMatrix;
    out.gl_Position = mul(param, param_1);
    out.v_PixelCoord = in.a_TexCoord * u_NewResolution;
    float2 _59 = float2(1.0) / u_NewResolution;
    out.v_PixelSize.x = _59.x;
    out.v_PixelSize.y = _59.y;
    float2 _71 = float2(1.0) / g_Texture0Resolution.xy;
    out.v_PixelSize.z = _71.x;
    out.v_PixelSize.w = _71.y;
    return out;
}

