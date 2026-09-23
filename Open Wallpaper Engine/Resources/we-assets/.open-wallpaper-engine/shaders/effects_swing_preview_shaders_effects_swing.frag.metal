#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 out_FragColor [[color(0)]];
};

struct main0_in
{
    float2 v_TexCoord [[user(locn0)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant float4& g_Texture0Resolution [[buffer(0)]], constant float2& g_Point0 [[buffer(1)]], constant float2& g_Point1 [[buffer(2)]], constant float& g_CenterPos [[buffer(3)]], constant float& g_Amount [[buffer(4)]], constant float& g_Speed [[buffer(5)]], constant float& g_Time [[buffer(6)]], constant float& g_Feather [[buffer(7)]], constant float& g_Size [[buffer(8)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float2 texCoord = in.v_TexCoord;
    float aspect = g_Texture0Resolution.x / g_Texture0Resolution.y;
    float2 p0 = g_Point0;
    float2 p1 = g_Point1;
    p0.x *= aspect;
    p1.x *= aspect;
    texCoord.x *= aspect;
    float2 axis = fast::normalize(p1 - p0);
    float2 center = p0 + ((p1 - p0) * g_CenterPos);
    float distortAmt = g_Amount;
    float speed = g_Speed;
    axis = fast::normalize(axis);
    float2 axisOrtho = float2(-axis.y, axis.x);
    float2 uvDelta = texCoord - center;
    float distanceAlongAxis = dot(axis, uvDelta);
    float distanceOrtho = dot(axisOrtho, uvDelta);
    float anim = sin(g_Time * speed);
    distortAmt *= anim;
    float2 uvDistort = ((axis * distortAmt) * distanceOrtho) * distanceAlongAxis;
    uvDistort += (((axisOrtho * distortAmt) * anim) * distanceOrtho);
    texCoord += uvDistort;
    float mask = 1.0;
    float feather = fast::max(g_Feather, 9.9999997473787516355514526367188e-06);
    float2 deltaRight = texCoord - p1;
    float2 deltaLeft = texCoord - p0;
    float distanceRight = dot(deltaRight, axis);
    float distanceLeft = dot(deltaLeft, axis);
    mask *= smoothstep(feather, 0.0, distanceRight);
    mask *= smoothstep(-feather, 0.0, distanceLeft);
    float sizeMod = g_Size;
    sizeMod = g_Size * (1.0 - ((abs(anim) * g_Amount) * 0.5));
    mask *= smoothstep(sizeMod + feather, sizeMod - feather, distanceOrtho);
    mask *= step(0.0, distanceOrtho);
    texCoord.x /= aspect;
    texCoord = mix(in.v_TexCoord, texCoord, float2(mask));
    out.out_FragColor = g_Texture0.sample(g_Texture0Smplr, texCoord);
    return out;
}

