#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 out_FragColor [[color(0)]];
};

fragment main0_out main0(constant float3& color [[buffer(0)]], constant float& g_Alpha [[buffer(1)]])
{
    main0_out out = {};
    out.out_FragColor = float4(color * 0.699999988079071044921875, g_Alpha);
    return out;
}

