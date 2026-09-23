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
    float2 v_TexCoordSoftMask [[user(locn2)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant float2& g_SpinCenter [[buffer(0)]], constant float& g_Size [[buffer(1)]], constant float& g_Feather [[buffer(2)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float2 texCoord = in.v_TexCoord.xy;
    out.out_FragColor = g_Texture0.sample(g_Texture0Smplr, texCoord);
    float2 maskDelta = in.v_TexCoordSoftMask - g_SpinCenter;
    float mask = smoothstep((g_Size + g_Feather) + 9.9999997473787516355514526367188e-06, g_Size - g_Feather, length(maskDelta));
    out.out_FragColor = mix(g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.zw), out.out_FragColor, float4(mask));
    return out;
}

