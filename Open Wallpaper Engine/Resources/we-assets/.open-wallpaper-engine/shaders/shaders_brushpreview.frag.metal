#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 out_FragColor [[color(0)]];
};

struct main0_in
{
    float2 g_TexCoord [[user(locn0)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant float4& g_RenderVar0 [[buffer(0)]])
{
    main0_out out = {};
    float dist = length(in.g_TexCoord - float2(0.5)) / 0.5;
    float delta = (1.0 - (0.4999000132083892822265625 * g_RenderVar0.y)) - (0.4999000132083892822265625 * g_RenderVar0.y);
    dist = (dist - (0.4999000132083892822265625 * g_RenderVar0.y)) / delta;
    dist = 1.0 - fast::max(0.0, fast::min(1.0, dist));
    dist = fast::max(0.0, fast::min(1.0, dist));
    out.out_FragColor = float4(1.0, 0.0, 0.0, dist * g_RenderVar0.x);
    return out;
}

