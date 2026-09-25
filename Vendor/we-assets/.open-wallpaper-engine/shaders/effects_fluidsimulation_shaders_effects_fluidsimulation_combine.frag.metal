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
float3 rgb2hsv(thread const float3& RGB)
{
    float4 _75;
    if (RGB.y < RGB.z)
    {
        _75 = float4(RGB.zy, -1.0, 0.666666686534881591796875);
    }
    else
    {
        _75 = float4(RGB.yz, 0.0, -0.3333333432674407958984375);
    }
    float4 P = _75;
    float4 _100;
    if (RGB.x < P.x)
    {
        _100 = float4(P.xyw, RGB.x);
    }
    else
    {
        _100 = float4(RGB.x, P.yzx);
    }
    float4 Q = _100;
    float C = Q.x - fast::min(Q.w, Q.y);
    float H = abs(((Q.w - Q.y) / ((6.0 * C) + 1.0000000133514319600180897396058e-10)) + Q.z);
    float3 HCV = float3(H, C, Q.x);
    float S = HCV.y / (HCV.z + 1.0000000133514319600180897396058e-10);
    return float3(HCV.x, S, HCV.z);
}

static inline __attribute__((always_inline))
float3 hsv2rgb(thread const float3& c)
{
    float4 K = float4(1.0, 0.666666686534881591796875, 0.3333333432674407958984375, 3.0);
    float3 p = abs((fract(c.xxx + K.xyz) * 6.0) - K.www);
    return mix(K.xxx, fast::clamp(p - K.xxx, float3(0.0), float3(1.0)), float3(c.y)) * c.z;
}

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return A + (B * opacity);
}

fragment main0_out main0(main0_in in [[stage_in]], constant float& u_HueShift [[buffer(0)]], constant float& u_Brightness [[buffer(1)]], constant float& u_Feather [[buffer(2)]], constant float& u_Alpha [[buffer(3)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture3 [[texture(1)]], texture2d<float> g_Texture1 [[texture(2)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture3Smplr [[sampler(1)]], sampler g_Texture1Smplr [[sampler(2)]])
{
    main0_out out = {};
    float2 fxCoords = in.v_TexCoord;
    float fxMask = 1.0;
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, fxCoords);
    float refAlpha = albedo.w;
    float4 gradientColor = g_Texture3.sample(g_Texture3Smplr, float2(albedo.x, 0.5));
    float3 param = gradientColor.xyz;
    float3 hsv = rgb2hsv(param);
    hsv.x += u_HueShift;
    float3 param_1 = hsv;
    float3 _222 = hsv2rgb(param_1) * u_Brightness;
    albedo.x = _222.x;
    albedo.y = _222.y;
    albedo.z = _222.z;
    albedo.w *= gradientColor.w;
    albedo.w = smoothstep(0.0, u_Feather, albedo.w);
    albedo.w *= fxMask;
    float4 prev = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord);
    float3 param_2 = prev.xyz;
    float3 param_3 = albedo.xyz;
    float param_4 = albedo.w * u_Alpha;
    float3 _264 = ApplyBlending(31, param_2, param_3, param_4);
    albedo.x = _264.x;
    albedo.y = _264.y;
    albedo.z = _264.z;
    albedo.w = fast::clamp(prev.w + albedo.w, 0.0, 1.0);
    out.out_FragColor = albedo;
    return out;
}

