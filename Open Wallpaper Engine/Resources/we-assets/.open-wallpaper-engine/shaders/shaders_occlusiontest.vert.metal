#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
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

vertex main0_out main0(main0_in in [[stage_in]], constant float3& g_ViewRight [[buffer(0)]], constant float3& g_ViewUp [[buffer(1)]], constant float4x4& g_ModelViewProjectionMatrix [[buffer(2)]])
{
    main0_out out = {};
    float3 position = in.a_Position + (((g_ViewRight * (in.a_TexCoord.x - 0.5)) + (g_ViewUp * (in.a_TexCoord.y - 0.5))) * 0.5);
    float4 param = float4(position, 1.0);
    float4x4 param_1 = g_ModelViewProjectionMatrix;
    out.gl_Position = mul(param, param_1);
    out.gl_Position.z = 0.999000012874603271484375 * out.gl_Position.w;
    return out;
}

