#pragma clang diagnostic ignored "-Wmissing-prototypes"

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

static inline __attribute__((always_inline))
float4 sampleF(thread const float4& a, thread const float4& b, thread const float4& c)
{
    return fast::max(a, fast::max(b, c));
}

fragment main0_out main0(main0_in in [[stage_in]], constant float4& g_Texture0Resolution [[buffer(0)]], constant float& g_RippleSpeed [[buffer(1)]], constant float& g_Frametime [[buffer(2)]], constant float& g_RippleDecay [[buffer(3)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float2 srcCoords = in.v_TexCoord;
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, srcCoords);
    float2 simTexel = float2(1.0) / g_Texture0Resolution.xy;
    float2 rippleOffset = ((simTexel * 100.0) * g_RippleSpeed) * g_Frametime;
    float2 insideRipple = rippleOffset * 1.61000001430511474609375;
    float2 outsideRipple = rippleOffset;
    float reflectUp = 0.0;
    float reflectDown = 0.0;
    float reflectLeft = 0.0;
    float reflectRight = 0.0;
    float4 uc = g_Texture0.sample(g_Texture0Smplr, (srcCoords + float2(0.0, -insideRipple.y)));
    float4 u00 = g_Texture0.sample(g_Texture0Smplr, (srcCoords + float2(-outsideRipple.x, -outsideRipple.y)));
    float4 u10 = g_Texture0.sample(g_Texture0Smplr, (srcCoords + float2(outsideRipple.x, -outsideRipple.y)));
    float4 dc = g_Texture0.sample(g_Texture0Smplr, (srcCoords + float2(0.0, insideRipple.y)));
    float4 d01 = g_Texture0.sample(g_Texture0Smplr, (srcCoords + float2(-outsideRipple.x, outsideRipple.y)));
    float4 d11 = g_Texture0.sample(g_Texture0Smplr, (srcCoords + float2(outsideRipple.x, outsideRipple.y)));
    float4 lc = g_Texture0.sample(g_Texture0Smplr, (srcCoords + float2(-insideRipple.x, 0.0)));
    float4 l00 = g_Texture0.sample(g_Texture0Smplr, (srcCoords + float2(-outsideRipple.x, -outsideRipple.y)));
    float4 l01 = g_Texture0.sample(g_Texture0Smplr, (srcCoords + float2(-outsideRipple.x, outsideRipple.y)));
    float4 rc = g_Texture0.sample(g_Texture0Smplr, (srcCoords + float2(insideRipple.x, 0.0)));
    float4 r10 = g_Texture0.sample(g_Texture0Smplr, (srcCoords + float2(outsideRipple.x, -outsideRipple.y)));
    float4 r11 = g_Texture0.sample(g_Texture0Smplr, (srcCoords + float2(outsideRipple.x, outsideRipple.y)));
    float4 param = uc;
    float4 param_1 = u00;
    float4 param_2 = u10;
    float4 up = sampleF(param, param_1, param_2);
    float4 param_3 = dc;
    float4 param_4 = d01;
    float4 param_5 = d11;
    float4 down = sampleF(param_3, param_4, param_5);
    float4 param_6 = lc;
    float4 param_7 = l00;
    float4 param_8 = l01;
    float4 left = sampleF(param_6, param_7, param_8);
    float4 param_9 = rc;
    float4 param_10 = r10;
    float4 param_11 = r11;
    float4 right = sampleF(param_9, param_10, param_11);
    float reflectionScale = 1.0;
    float4 force = float4(0.0);
    float componentScale = 0.3333333432674407958984375;
    float4 reflectionMask = (float4(1.0) - (float4(reflectRight, reflectDown, reflectLeft, reflectUp) * 0.89999997615814208984375)) * componentScale;
    float4 _247 = force;
    float3 _249 = _247.xzy + (up.xzy * reflectionMask.xzy);
    force.x = _249.x;
    force.z = _249.y;
    force.y = _249.z;
    float4 _262 = force;
    float3 _264 = _262.xzw + (down.xzw * reflectionMask.xzw);
    force.x = _264.x;
    force.z = _264.y;
    force.w = _264.z;
    float4 _277 = force;
    float3 _279 = _277.xyw + (left.xyw * reflectionMask.xyw);
    force.x = _279.x;
    force.y = _279.y;
    force.w = _279.z;
    float4 _291 = force;
    float3 _293 = _291.zyw + (right.zyw * reflectionMask.zyw);
    force.z = _293.x;
    force.y = _293.y;
    force.w = _293.z;
    float decay = 1.5;
    float drop = fast::max(0.003925490193068981170654296875, ((decay / 255.0) * (g_Frametime / 0.0199999995529651641845703125)) * g_RippleDecay);
    force -= float4(drop);
    albedo = force;
    out.out_FragColor = albedo;
    return out;
}

