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
    float4 v_PointerUV [[user(locn1)]];
    float4 v_PointerUVLast [[user(locn2)]];
    float2 v_PointDelta [[user(locn3)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant float& g_Frametime [[buffer(0)]], constant float4& g_PointerState [[buffer(1)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float2 texSource = in.v_TexCoord;
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, texSource);
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
    float timeAmt = fast::min(0.0333333350718021392822265625, g_Frametime) / 0.0199999995529651641845703125;
    float pointerMoveAmt = in.v_PointDelta.x;
    float inputStrength = (pointerDist * timeAmt) * (pointerMoveAmt + (g_PointerState.z * 5.0));
    float2 impulseDir = fast::max(float2(-1.0), fast::min(float2(1.0), unprojectedUVs));
    float4 colorAdd = float4((step(0.0, impulseDir.x) * impulseDir.x) * inputStrength, (step(0.0, impulseDir.y) * impulseDir.y) * inputStrength, (step(impulseDir.x, 0.0) * (-impulseDir.x)) * inputStrength, (step(impulseDir.y, 0.0) * (-impulseDir.y)) * inputStrength);
    out.out_FragColor = albedo + colorAdd;
    return out;
}

