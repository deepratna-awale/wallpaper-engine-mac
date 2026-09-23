#pragma clang diagnostic ignored "-Wmissing-prototypes"
#pragma clang diagnostic ignored "-Wmissing-braces"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

template<typename T, size_t Num>
struct spvUnsafeArray
{
    T elements[Num ? Num : 1];
    
    thread T& operator [] (size_t pos) thread
    {
        return elements[pos];
    }
    constexpr const thread T& operator [] (size_t pos) const thread
    {
        return elements[pos];
    }
    
    device T& operator [] (size_t pos) device
    {
        return elements[pos];
    }
    constexpr const device T& operator [] (size_t pos) const device
    {
        return elements[pos];
    }
    
    constexpr const constant T& operator [] (size_t pos) const constant
    {
        return elements[pos];
    }
    
    threadgroup T& operator [] (size_t pos) threadgroup
    {
        return elements[pos];
    }
    constexpr const threadgroup T& operator [] (size_t pos) const threadgroup
    {
        return elements[pos];
    }
};

struct main0_out
{
    float4 out_FragColor [[color(0)]];
};

struct main0_in
{
    float3 v_Normal [[user(locn0)]];
    float2 v_TexCoord [[user(locn1)]];
    float3 v_ViewDir [[user(locn2)]];
    float4 v_Light0DirectionL3X [[user(locn3)]];
    float4 v_Light1DirectionL3Y [[user(locn4)]];
    float4 v_Light2DirectionL3Z [[user(locn5)]];
    float3 v_LightAmbientColor [[user(locn6)]];
};

static inline __attribute__((always_inline))
float ComputeMaterialSpecularPower(float roughness, float metallic)
{
    return (1.0099999904632568359375 - roughness) * mix(400.0, 250.0, metallic);
}

static inline __attribute__((always_inline))
float ComputeMaterialSpecularStrength(float roughness, float metallic)
{
    return (0.5 + (metallic * 0.5)) * (1.0 - (roughness * 0.89999997615814208984375));
}

static inline __attribute__((always_inline))
float3 ComputeLightSpecular(float3 normal, float3 lightDelta, float3 color, float radius, float3 viewDir, float specularPower, float specularStrength, float halfLambert, float metallicTerm, thread float3& specularResult)
{
    float lightDistance = length(lightDelta);
    float lightAttn = fast::clamp((radius - lightDistance) / radius, 0.0, 1.0);
    float3 lightDir = lightDelta / float3(lightDistance);
    float specular = fast::max(0.0, dot(fast::normalize(viewDir + lightDir), normal));
    specularResult += (color * ((powr(specular, specularPower) * specularStrength) * lightAttn));
    float lightDot = dot(lightDir, normal);
    float halfLambertLight = (lightDot * 0.5) + 0.5;
    lightDot = mix(lightDot, halfLambertLight, halfLambert);
    float rim = metallicTerm * 2.0;
    rim = powr((1.0 - fast::clamp(dot(normal, viewDir), 0.0, 1.0)) * powr(halfLambertLight, 0.25), 6.0 - rim) * rim;
    return ((color * (fast::clamp(lightDot, 0.0, 1.0) + rim)) * lightAttn) * lightAttn;
}

fragment main0_out main0(main0_in in [[stage_in]], constant float3& g_TintColor [[buffer(0)]], constant float& g_TintAlpha [[buffer(1)]], constant float& g_Roughness [[buffer(2)]], constant float& g_Metallic [[buffer(3)]], constant spvUnsafeArray<float4, 4>& g_LightsColorRadius [[buffer(4)]], constant float& g_Light [[buffer(8)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float3 specularResult = float3(0.0);
    float4 _131 = albedo;
    float3 _133 = _131.xyz * g_TintColor;
    albedo.x = _133.x;
    albedo.y = _133.y;
    albedo.z = _133.z;
    albedo.w *= g_TintAlpha;
    float3 viewDir = fast::normalize(in.v_ViewDir);
    float specularPower = ComputeMaterialSpecularPower(g_Roughness, g_Metallic);
    float specularStrength = ComputeMaterialSpecularStrength(g_Roughness, g_Metallic);
    float3 normal = fast::normalize(in.v_Normal);
    float3 param = specularResult;
    float3 _197 = ComputeLightSpecular(normal, in.v_Light0DirectionL3X.xyz, g_LightsColorRadius[0].xyz, g_LightsColorRadius[0].w, viewDir, specularPower, specularStrength, g_Light, g_Metallic, param);
    specularResult = param;
    float3 light = _197;
    float3 param_1 = specularResult;
    float3 _216 = ComputeLightSpecular(normal, in.v_Light1DirectionL3Y.xyz, g_LightsColorRadius[1].xyz, g_LightsColorRadius[1].w, viewDir, specularPower, specularStrength, g_Light, g_Metallic, param_1);
    specularResult = param_1;
    light += _216;
    float3 param_2 = specularResult;
    float3 _237 = ComputeLightSpecular(normal, in.v_Light2DirectionL3Z.xyz, g_LightsColorRadius[2].xyz, g_LightsColorRadius[2].w, viewDir, specularPower, specularStrength, g_Light, g_Metallic, param_2);
    specularResult = param_2;
    light += _237;
    float3 param_3 = specularResult;
    float3 _263 = ComputeLightSpecular(normal, float3(in.v_Light0DirectionL3X.w, in.v_Light1DirectionL3Y.w, in.v_Light2DirectionL3Z.w), g_LightsColorRadius[3].xyz, g_LightsColorRadius[3].w, viewDir, specularPower, specularStrength, g_Light, g_Metallic, param_3);
    specularResult = param_3;
    light += _263;
    light += in.v_LightAmbientColor;
    float4 _271 = albedo;
    float3 _276 = (_271.xyz * light) + specularResult;
    albedo.x = _276.x;
    albedo.y = _276.y;
    albedo.z = _276.z;
    out.out_FragColor = albedo;
    return out;
}

