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

fragment main0_out main0(main0_in in [[stage_in]], constant float& g_Alpha [[buffer(0)]])
{
    main0_out out = {};
    float fade = smoothstep(0.20000000298023223876953125, 0.300000011920928955078125, in.v_TexCoord.y) * smoothstep(0.800000011920928955078125, 0.699999988079071044921875, in.v_TexCoord.y);
    out.out_FragColor = float4(0.0, 0.0, 0.0, fade * g_Alpha);
    return out;
}

