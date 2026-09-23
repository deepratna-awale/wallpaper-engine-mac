#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 v_Color [[user(locn0)]];
    float2 v_TexCoord [[user(locn1)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float4 a_TexCoordVec4 [[attribute(1)]];
    float4 a_Color [[attribute(2)]];
    float2 a_TexCoordC2 [[attribute(3)]];
};

static inline __attribute__((always_inline))
float3x3 mul(thread const float3x3& left, thread const float3x3& right)
{
    return left * right;
}

static inline __attribute__((always_inline))
float3 mul(thread const float3& value, thread const float3x3& matrix)
{
    return matrix * value;
}

static inline __attribute__((always_inline))
void ComputeParticleTangents(thread const float3& rotation, thread float3& right, thread float3& up, constant float3& g_OrientationRight, constant float3& g_OrientationUp, constant float3& g_OrientationForward)
{
    float3 rCos = cos(rotation);
    float3 rSin = sin(rotation);
    float3x3 param = float3x3(float3(rCos.z, -rSin.z, 0.0), float3(rSin.z, rCos.z, 0.0), float3(0.0, 0.0, 1.0));
    float3x3 param_1 = float3x3(float3(1.0, 0.0, 0.0), float3(0.0, rCos.x, -rSin.x), float3(0.0, rSin.x, rCos.x));
    float3x3 param_2 = mul(param, param_1);
    float3x3 param_3 = float3x3(float3(rCos.y, 0.0, rSin.y), float3(0.0, 1.0, 0.0), float3(-rSin.y, 0.0, rCos.y));
    float3x3 mRotation = mul(param_2, param_3);
    float3x3 param_4 = mRotation;
    float3x3 param_5 = float3x3(float3(g_OrientationRight), float3(g_OrientationUp), float3(g_OrientationForward));
    mRotation = mul(param_4, param_5);
    float3 param_6 = float3(1.0, 0.0, 0.0);
    float3x3 param_7 = mRotation;
    right = mul(param_6, param_7);
    float3 param_8 = float3(0.0, 1.0, 0.0);
    float3x3 param_9 = mRotation;
    up = mul(param_8, param_9);
}

static inline __attribute__((always_inline))
float3 ComputeParticlePosition(thread const float2& uvs, thread const float& textureRatio, thread const float4& positionAndSize, thread const float3& right, thread const float3& up)
{
    return positionAndSize.xyz + (((right * positionAndSize.w) * (uvs.x - 0.5)) - (((up * positionAndSize.w) * (uvs.y - 0.5)) * textureRatio));
}

static inline __attribute__((always_inline))
float4 mul(thread const float4& value, thread const float4x4& matrix)
{
    return matrix * value;
}

vertex main0_out main0(main0_in in [[stage_in]], constant float3& g_OrientationRight [[buffer(0)]], constant float3& g_OrientationUp [[buffer(1)]], constant float3& g_OrientationForward [[buffer(2)]], constant float4& g_Texture0Resolution [[buffer(3)]], constant float4x4& g_ModelViewProjectionMatrix [[buffer(4)]])
{
    main0_out out = {};
    float textureRatio = g_Texture0Resolution.y / g_Texture0Resolution.x;
    float3 param = float3(in.a_TexCoordC2, in.a_TexCoordVec4.z);
    float3 param_1;
    float3 param_2;
    ComputeParticleTangents(param, param_1, param_2, g_OrientationRight, g_OrientationUp, g_OrientationForward);
    float3 right = param_1;
    float3 up = param_2;
    float2 param_3 = in.a_TexCoordVec4.xy;
    float param_4 = textureRatio;
    float4 param_5 = float4(in.a_Position, in.a_TexCoordVec4.w);
    float3 param_6 = right;
    float3 param_7 = up;
    float3 position = ComputeParticlePosition(param_3, param_4, param_5, param_6, param_7);
    float4 param_8 = float4(position, 1.0);
    float4x4 param_9 = g_ModelViewProjectionMatrix;
    out.gl_Position = mul(param_8, param_9);
    out.v_TexCoord = in.a_TexCoordVec4.xy;
    out.v_Color = in.a_Color;
    return out;
}

