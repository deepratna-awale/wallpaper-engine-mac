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
float2 blurRotateVec2(thread const float2& v, thread const float& r)
{
    float2 cs = float2(cos(r), sin(r));
    return float2((v.x * cs.x) - (v.y * cs.y), (v.x * cs.y) + (v.y * cs.x));
}

static inline __attribute__((always_inline))
float4 blurRadial13a(thread const float2& u, thread const float2& center, thread float& amt, texture2d<float> g_Texture0, sampler g_Texture0Smplr)
{
    float2 delta = u - center;
    amt *= 0.02500000037252902984619140625;
    float o1 = 1.40919983386993408203125 * amt;
    float o2 = 3.2979347705841064453125 * amt;
    float o3 = 5.20629024505615234375 * amt;
    float2 param = delta;
    float param_1 = o1;
    float2 r1 = blurRotateVec2(param, param_1) - delta;
    float2 param_2 = delta;
    float param_3 = o2;
    float2 r2 = blurRotateVec2(param_2, param_3) - delta;
    float2 param_4 = delta;
    float param_5 = o3;
    float2 r3 = blurRotateVec2(param_4, param_5) - delta;
    return ((((((g_Texture0.sample(g_Texture0Smplr, u) * 0.1976406574249267578125) + (g_Texture0.sample(g_Texture0Smplr, ((center + r1) + delta)) * 0.295985519886016845703125)) + (g_Texture0.sample(g_Texture0Smplr, ((center - r1) + delta)) * 0.295985519886016845703125)) + (g_Texture0.sample(g_Texture0Smplr, ((center + r2) + delta)) * 0.093533359467983245849609375)) + (g_Texture0.sample(g_Texture0Smplr, ((center - r2) + delta)) * 0.093533359467983245849609375)) + (g_Texture0.sample(g_Texture0Smplr, ((center + r3) + delta)) * 0.01166080497205257415771484375)) + (g_Texture0.sample(g_Texture0Smplr, ((center - r3) + delta)) * 0.01166080497205257415771484375);
}

fragment main0_out main0(main0_in in [[stage_in]], constant float2& u_Center [[buffer(0)]], constant float& u_Scale [[buffer(1)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float2 param = in.v_TexCoord;
    float2 param_1 = u_Center;
    float param_2 = u_Scale;
    float4 _181 = blurRadial13a(param, param_1, param_2, g_Texture0, g_Texture0Smplr);
    float4 albedo = _181;
    out.out_FragColor = albedo;
    return out;
}

