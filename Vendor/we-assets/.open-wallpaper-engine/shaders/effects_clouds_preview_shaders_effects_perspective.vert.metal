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
    float2 p3 = float2(g_Top, g_Left);
    float2 p2 = float2(1.0 - g_Top, g_Right);
    float2 p1 = float2(1.0 - g_Bottom, 1.0 - g_Right);
    float2 p0 = float2(g_Bottom, 1.0 - g_Left);
    float ax = p2.x - p0.x;
    float ay = p2.y - p0.y;
    float bx = p3.x - p1.x;
    float by = p3.y - p1.y;
    float _cross = (ax * by) - (ay * bx);
    float cy = p0.y - p1.y;
    float cx = p0.x - p1.x;
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
    float3 _187 = out.v_TexCoord;
    float2 _189 = _187.xy * q;
    out.v_TexCoord.x = _189.x;
    out.v_TexCoord.y = _189.y;
    out.v_TexCoord.z = q;
    out.gl_Position = float4(position, 1.0) * g_ModelViewProjectionMatrix;
    return out;
}

