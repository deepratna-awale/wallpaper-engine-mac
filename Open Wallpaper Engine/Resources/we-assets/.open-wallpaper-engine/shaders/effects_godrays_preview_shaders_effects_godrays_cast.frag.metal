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

fragment main0_out main0(main0_in in [[stage_in]], constant float2& g_Center [[buffer(0)]], constant float& g_Length [[buffer(1)]], constant float3& g_Color2 [[buffer(2)]], constant float3& g_Color1 [[buffer(3)]], constant float& g_Intensity [[buffer(4)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float2 texCoords = in.v_TexCoord;
    float4 albedo = float4(0.0);
    float2 direction = g_Center - texCoords;
    float dist = length(direction);
    direction /= float2(dist);
    dist = fast::min(dist, dist * g_Length);
    texCoords += (direction * dist);
    direction = (direction * dist) / float2(29.0);
    for (int i = 0; i < 30; i++)
    {
        float4 sampleValue = g_Texture0.sample(g_Texture0Smplr, texCoords);
        texCoords -= direction;
        float4 _85 = sampleValue;
        float3 _87 = _85.xyz * mix(g_Color2, g_Color1, float3(float(i) / 29.0));
        sampleValue.x = _87.x;
        sampleValue.y = _87.y;
        sampleValue.z = _87.z;
        albedo += (sampleValue * (float(i) / 29.0));
    }
    out.out_FragColor = (albedo * g_Intensity) * 0.100000001490116119384765625;
    return out;
}

