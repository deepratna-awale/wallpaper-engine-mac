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
float2 rotateVec2(thread const float2& value, thread const float& angle)
{
    float s = sin(angle);
    float c = cos(angle);
    return float2((value.x * c) - (value.y * s), (value.x * s) + (value.y * c));
}

fragment main0_out main0(main0_in in [[stage_in]], constant float4& g_Texture0Resolution [[buffer(0)]], constant float2& g_SpinCenter [[buffer(1)]], constant float& g_Size [[buffer(2)]], constant float& g_Feather [[buffer(3)]], constant float& g_Time [[buffer(4)]], constant float& g_Speed [[buffer(5)]], constant float& g_Amount [[buffer(6)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float aspect = g_Texture0Resolution.z / g_Texture0Resolution.w;
    float2 texCoord = in.v_TexCoord;
    texCoord -= g_SpinCenter;
    texCoord.x *= aspect;
    float feather = smoothstep((g_Size + g_Feather) + 9.9999997473787516355514526367188e-06, g_Size - g_Feather, length(texCoord));
    float dist = length(texCoord) / g_Size;
    float anim = (sin(g_Time * g_Speed) * dist) * g_Amount;
    float2 param = texCoord;
    float param_1 = anim;
    texCoord = rotateVec2(param, param_1);
    texCoord.x /= aspect;
    texCoord += g_SpinCenter;
    texCoord = mix(in.v_TexCoord, texCoord, float2(feather));
    out.out_FragColor = g_Texture0.sample(g_Texture0Smplr, texCoord);
    float mask = 1.0;
    out.out_FragColor = mix(g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord), out.out_FragColor, float4(mask));
    return out;
}

