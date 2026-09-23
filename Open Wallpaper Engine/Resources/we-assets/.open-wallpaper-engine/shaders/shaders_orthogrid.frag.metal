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
    float4 v_ViewRect [[user(locn1)]];
};

fragment main0_out main0(main0_in in [[stage_in]])
{
    main0_out out = {};
    float4 color = float4(0.0);
    float s = sin((in.v_TexCoord.y - in.v_TexCoord.x) * 0.0350000001490116119384765625);
    float4 grid = float4(1.0, 1.0, 0.0, 0.20000000298023223876953125) * smoothstep(0.699999988079071044921875, 0.800000011920928955078125, abs(s));
    float f = (step(in.v_TexCoord.x, in.v_ViewRect.x) + step(in.v_ViewRect.z, in.v_TexCoord.x)) + (step(in.v_TexCoord.y, in.v_ViewRect.y) + step(in.v_ViewRect.w, in.v_TexCoord.y));
    color = mix(color, grid, float4(fast::clamp(f, 0.0, 1.0)));
    float borderWidth = 10.0;
    float rightBorder = (step(in.v_ViewRect.x - borderWidth, in.v_TexCoord.x) * step(in.v_TexCoord.x, in.v_ViewRect.x)) + (step(in.v_ViewRect.z, in.v_TexCoord.x) * step(in.v_TexCoord.x, in.v_ViewRect.z + borderWidth));
    float rightBorderMask = step(in.v_TexCoord.y, in.v_ViewRect.w + borderWidth) * step(in.v_ViewRect.y - borderWidth, in.v_TexCoord.y);
    float leftBorder = (step(in.v_ViewRect.y - borderWidth, in.v_TexCoord.y) * step(in.v_TexCoord.y, in.v_ViewRect.y)) + (step(in.v_ViewRect.w, in.v_TexCoord.y) * step(in.v_TexCoord.y, in.v_ViewRect.w + borderWidth));
    float leftBorderMask = step(in.v_TexCoord.x, in.v_ViewRect.z + borderWidth) * step(in.v_ViewRect.x - borderWidth, in.v_TexCoord.x);
    float border = (rightBorder * rightBorderMask) + (leftBorder * leftBorderMask);
    color = mix(color, float4(1.0, 1.0, 0.0, 0.5), float4(fast::clamp(border, 0.0, 1.0)));
    out.out_FragColor = color;
    return out;
}

