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
    float4 v_TexCoordLeftTop [[user(locn1)]];
    float4 v_TexCoordRightBottom [[user(locn2)]];
    float4 v_PointerUV [[user(locn3)]];
    float4 v_PointerUVLast [[user(locn4)]];
    float2 v_PointDelta [[user(locn5)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant float& g_Frametime [[buffer(0)]], constant float& u_Curl [[buffer(1)]], constant float4& g_Texture0Resolution [[buffer(2)]], constant float4& g_PointerState [[buffer(3)]], texture2d<float> g_Texture1 [[texture(0)]], texture2d<float> g_Texture0 [[texture(1)]], sampler g_Texture1Smplr [[sampler(0)]], sampler g_Texture0Smplr [[sampler(1)]])
{
    main0_out out = {};
    float dt = fast::min(0.0500000007450580596923828125, g_Frametime);
    float2 vUv = in.v_TexCoord;
    float2 vL = in.v_TexCoordLeftTop.xy;
    float2 vR = in.v_TexCoordRightBottom.xy;
    float2 vT = in.v_TexCoordLeftTop.zw;
    float2 vB = in.v_TexCoordRightBottom.zw;
    float L = g_Texture1.sample(g_Texture1Smplr, vL).x;
    float R = g_Texture1.sample(g_Texture1Smplr, vR).x;
    float T = g_Texture1.sample(g_Texture1Smplr, vT).x;
    float B = g_Texture1.sample(g_Texture1Smplr, vB).x;
    float C = g_Texture1.sample(g_Texture1Smplr, vUv).x;
    float2 force = float2(abs(T) - abs(B), abs(R) - abs(L)) * 0.5;
    force /= float2(length(force) + 9.9999997473787516355514526367188e-05);
    force *= (u_Curl * C);
    force.y *= (-1.0);
    float2 velocity = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord).xy;
    velocity += (force * dt);
    velocity = fast::min(fast::max(velocity, float2(-1000.0)), float2(1000.0));
    float2 emitterUV = in.v_TexCoord;
    float aspect = g_Texture0Resolution.y / g_Texture0Resolution.x;
    float2 texSource = in.v_TexCoord;
    float2 unprojectedUVs = in.v_PointerUV.xy;
    float2 unprojectedUVsLast = in.v_PointerUVLast.xy;
    float rippleMask = 1.0;
    float2 lDelta = unprojectedUVs - unprojectedUVsLast;
    float2 texDelta = texSource - unprojectedUVsLast;
    float distLDelta = length(lDelta) + 9.9999997473787516355514526367188e-05;
    lDelta /= float2(distLDelta);
    float distOnLine = dot(lDelta, texDelta);
    float rayMask = fast::max(step(0.0, distOnLine) * step(distOnLine, distLDelta), step(distLDelta, 0.100000001490116119384765625));
    distOnLine = fast::clamp(distOnLine / distLDelta, 0.0, 1.0) * distLDelta;
    float2 posOnLine = unprojectedUVsLast + (lDelta * distOnLine);
    unprojectedUVs = (texSource - posOnLine) * float2(in.v_PointDelta.y, in.v_PointerUV.w);
    float pointerDist = length(unprojectedUVs);
    pointerDist = fast::clamp(1.0 - pointerDist, 0.0, 1.0);
    pointerDist *= (rayMask * rippleMask);
    float timeAmt = 1.0;
    float pointerMoveAmt = in.v_PointDelta.x;
    float inputStrength = (pointerDist * timeAmt) * (pointerMoveAmt + g_PointerState.z);
    float2 impulseDir = lDelta;
    float2 colorAdd = float2(impulseDir.x * inputStrength, impulseDir.y * inputStrength);
    velocity += (colorAdd * 300.0);
    out.out_FragColor = float4(velocity, 0.0, 1.0);
    return out;
}

