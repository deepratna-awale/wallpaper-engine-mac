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

vertex main0_out main0(main0_in in [[stage_in]], constant float& g_Top [[buffer(0)]], constant float& g_Left [[buffer(1)]], constant float& g_Right [[buffer(2)]], constant float& g_Bottom [[buffer(3)]], constant float4x4& g_ModelViewProjectionMatrix [[buffer(4)]])
{
    main0_out out = {};
    float3 position = in.a_Position;
    out.v_TexCoord.x = in.a_TexCoord.x;
    out.v_TexCoord.y = in.a_TexCoord.y;
    out.v_TexCoord.z = 1.0;
    float p3x = g_Top;
    float p3y = g_Left;
    float p2x = 1.0 - g_Top;
    float p2y = g_Right;
    float p1x = 1.0 - g_Bottom;
    float p1y = 1.0 - g_Right;
    float p0x = g_Bottom;
    float p0y = 1.0 - g_Left;
    float ax = p2x - p0x;
    float ay = p2y - p0y;
    float bx = p3x - p1x;
    float by = p3y - p1y;
    float _cross = (ax * by) - (ay * bx);
    float cy = p0y - p1y;
    float cx = p0x - p1x;
    float s = ((ax * cy) - (ay * cx)) / _cross;
    float t = ((bx * cy) - (by * cx)) / _cross;
    float q0 = 1.0 / (1.0 - t);
    float q1 = 1.0 / (1.0 - s);
    float q2 = 1.0 / t;
    float q3 = 1.0 / s;
    float q = mix(mix(q3, q2, in.a_TexCoord.x), mix(q0, q1, in.a_TexCoord.x), in.a_TexCoord.y);
    out.v_TexCoord.x = in.a_TexCoord.x;
    out.v_TexCoord.y = in.a_TexCoord.y;
    out.v_TexCoord -= float3(0.5);
    out.v_TexCoord.x *= (0.5 / (0.5 - mix(g_Top, g_Bottom, step(0.5, in.a_TexCoord.y))));
    out.v_TexCoord.y *= (0.5 / (0.5 - mix(g_Left, g_Right, step(0.5, in.a_TexCoord.x))));
    out.v_TexCoord += float3(0.5);
    float3 _174 = out.v_TexCoord;
    float2 _176 = _174.xy * q;
    out.v_TexCoord.x = _176.x;
    out.v_TexCoord.y = _176.y;
    out.v_TexCoord.z = q;
    out.gl_Position = float4(position, 1.0) * g_ModelViewProjectionMatrix;
    return out;
}

