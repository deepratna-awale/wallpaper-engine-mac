#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 out_FragColor [[color(0)]];
};

struct main0_in
{
    float4 v_TexCoord [[user(locn0)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant float2& g_Point0 [[buffer(0)]], constant float2& g_Point1 [[buffer(1)]], constant float& g_CenterPos [[buffer(2)]], constant float& g_Feather [[buffer(3)]], constant float& g_Size [[buffer(4)]], constant float& g_Amount [[buffer(5)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float2 texCoord = in.v_TexCoord.xy;
    float aspect = in.v_TexCoord.z;
    float2 p0 = g_Point0;
    float2 p1 = g_Point1;
    p0.x *= aspect;
    p1.x *= aspect;
    texCoord.x *= aspect;
    float2 axis = fast::normalize(p1 - p0);
    float2 center = p0 + ((p1 - p0) * g_CenterPos);
    axis = fast::normalize(axis);
    float2 axisOrtho = float2(-axis.y, axis.x);
    float2 uvDelta = texCoord - center;
    float distanceAlongAxis = dot(axis, uvDelta);
    float distanceOrtho = dot(axisOrtho, uvDelta);
    float anim = in.v_TexCoord.w;
    float distortAmt = anim;
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
    texCoord = mix(in.v_TexCoord.xy, texCoord, float2(mask));
    out.out_FragColor = g_Texture0.sample(g_Texture0Smplr, texCoord);
    return out;
}

