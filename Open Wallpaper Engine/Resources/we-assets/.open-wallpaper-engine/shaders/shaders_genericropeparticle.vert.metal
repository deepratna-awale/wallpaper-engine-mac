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
    float4 a_PositionVec4 [[attribute(0)]];
    float4 a_TexCoordVec4 [[attribute(1)]];
    float4 a_TexCoordVec4C1 [[attribute(2)]];
    float3 a_TexCoordVec3C2 [[attribute(3)]];
    float2 a_TexCoordC3 [[attribute(4)]];
    float4 a_Color [[attribute(5)]];
};

static inline __attribute__((always_inline))
float3 mul(thread const float3& value, thread const float3x3& matrix)
{
    return matrix * value;
}

static inline __attribute__((always_inline))
float4 mul(thread const float4& value, thread const float4x4& matrix)
{
    return matrix * value;
}

vertex main0_out main0(main0_in in [[stage_in]], constant float3& g_OrientationForward [[buffer(0)]], constant float4x4& g_ModelMatrixInverse [[buffer(1)]], constant float4x4& g_ModelViewProjectionMatrix [[buffer(2)]])
{
    main0_out out = {};
    float3 startPosition = in.a_PositionVec4.xyz;
    float3 endPosition = in.a_TexCoordVec4.xyz;
    float3 CPStart = startPosition - in.a_TexCoordVec4C1.xyz;
    float sizeStart = in.a_PositionVec4.w;
    float4 colorStart = in.a_Color;
    float3 CPEnd = endPosition - in.a_TexCoordVec3C2;
    float sizeEnd = sizeStart;
    float4 colorEnd = in.a_Color;
    float2 uvs = in.a_TexCoordC3;
    float3 param = g_OrientationForward;
    float3x3 param_1 = float3x3(g_ModelMatrixInverse[0].xyz, g_ModelMatrixInverse[1].xyz, g_ModelMatrixInverse[2].xyz);
    float3 eyeDirection = mul(param, param_1);
    float3 trailDelta = endPosition - startPosition;
    float3 trailRightStart = cross(eyeDirection, trailDelta + CPStart);
    float3 trailRightEnd = cross(eyeDirection, trailDelta - CPEnd);
    float usableLength = in.a_TexCoordVec4.w - 1.0;
    float uvMinimum = 1.0 - (in.a_TexCoordVec4C1.w / usableLength);
    float uvDelta = (-1.0) / usableLength;
    float4 color = mix(colorStart, colorEnd, float4(uvs.y));
    trailRightStart = fast::normalize(trailRightStart) * sizeStart;
    trailRightEnd = fast::normalize(trailRightEnd) * sizeEnd;
    float3 position = mix(startPosition, endPosition, float3(uvs.y));
    float3 right = mix(trailRightStart, trailRightEnd, float3(uvs.y));
    position += (((right * uvs.x) * 2.0) - float3(1.0));
    float4 param_2 = float4(position, 1.0);
    float4x4 param_3 = g_ModelViewProjectionMatrix;
    out.gl_Position = mul(param_2, param_3);
    out.v_TexCoord = uvs;
    out.v_TexCoord.y = mix(uvMinimum, uvMinimum + uvDelta, uvs.y);
    out.v_Color = color;
    return out;
}

