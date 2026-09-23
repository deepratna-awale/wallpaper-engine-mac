#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 out_FragColor [[color(0)]];
};

struct main0_in
{
    float4 v_ScreenPos [[user(locn0)]];
    float4 v_ScreenNorm [[user(locn1)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant float& g_Alpha [[buffer(0)]])
{
    main0_out out = {};
    out.out_FragColor = float4(0.0, 0.0, 0.0, g_Alpha);
    float3 screenPos = in.v_ScreenPos.xyz / float3(in.v_ScreenPos.w);
    float3 screenNorm = fast::normalize(in.v_ScreenNorm.xyz);
    float light = dot(screenNorm, float3(0.57735025882720947265625));
    float lightPowd = light;
    lightPowd = powr(abs(lightPowd), 2.0) * sign(lightPowd);
    light = (light * 0.5) + 0.5;
    lightPowd = (lightPowd * 0.5) + 0.5;
    float3 shadow = float3(1.0);
    float3 mid = float3(1.0, 0.20000000298023223876953125, 0.0);
    float3 high = float3(0.0, 0.0, 1.5);
    float3 res = mix(mix(shadow, mid, float3(smoothstep(0.0, 0.5, lightPowd))), high, float3(smoothstep(0.5, 1.0, lightPowd)));
    res = float3(1.0);
    float3 _81 = res * powr(light, 0.699999988079071044921875);
    out.out_FragColor.x = _81.x;
    out.out_FragColor.y = _81.y;
    out.out_FragColor.z = _81.z;
    return out;
}

