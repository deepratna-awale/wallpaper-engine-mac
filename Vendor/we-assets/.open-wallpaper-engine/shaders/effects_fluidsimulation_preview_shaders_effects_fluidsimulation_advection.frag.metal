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

fragment main0_out main0(main0_in in [[stage_in]], constant float4& g_Texture0Resolution [[buffer(0)]], constant float& g_Frametime [[buffer(1)]], constant float& u_Viscosity [[buffer(2)]], constant float& m_Dissipation [[buffer(3)]], constant float& u_Lifetime [[buffer(4)]], constant float& u_ConstantVelocityAngle [[buffer(5)]], constant float& u_ConstantVelocityStrength [[buffer(6)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float2 vUv = in.v_TexCoord;
    float2 texelSize = float2(1.0) / g_Texture0Resolution.xy;
    float dt = fast::min(0.0500000007450580596923828125, g_Frametime);
    float2 coord = vUv - ((g_Texture0.sample(g_Texture0Smplr, vUv).xy * dt) * texelSize);
    float4 result = g_Texture1.sample(g_Texture1Smplr, coord);
    float decayFactor = u_Viscosity;
    float decay = 1.0 + ((decayFactor * m_Dissipation) * dt);
    float lowPass = step(length(result.xyz), u_Lifetime) * 0.5;
    out.out_FragColor = result / float4(decay + lowPass);
    float aspect = g_Texture0Resolution.y / g_Texture0Resolution.x;
    float2 constantSpeed = float2(sin(u_ConstantVelocityAngle), -cos(u_ConstantVelocityAngle)) * u_ConstantVelocityStrength;
    constantSpeed.y *= aspect;
    float4 _107 = out.out_FragColor;
    float2 _109 = _107.xy + (constantSpeed * g_Frametime);
    out.out_FragColor.x = _109.x;
    out.out_FragColor.y = _109.y;
    return out;
}

