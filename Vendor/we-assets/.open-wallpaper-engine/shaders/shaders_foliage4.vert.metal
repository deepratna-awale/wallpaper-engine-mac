#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 v_ViewDir [[user(locn0)]];
    float2 v_TexCoord [[user(locn1)]];
    float3 v_LightAmbientColor [[user(locn2)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float3 a_Normal [[attribute(1)]];
    float2 a_TexCoord [[attribute(2)]];
};

static inline __attribute__((always_inline))
float4 mul(thread const float4& value, thread const float4x4& matrix)
{
    return matrix * value;
}

static inline __attribute__((always_inline))
float3 mul(thread const float3& value, thread const float3x3& matrix)
{
    return matrix * value;
}

static inline __attribute__((always_inline))
void ApplyPositionNormal(thread const float3& position, thread const float3& normal, thread float4& worldPosition, thread float3& worldNormal, constant float4x4& g_ModelMatrix, constant float3x3& g_NormalModelMatrix)
{
    float4 param = float4(position, 1.0);
    float4x4 param_1 = g_ModelMatrix;
    worldPosition = mul(param, param_1);
    float3 param_2 = normal;
    float3x3 param_3 = g_NormalModelMatrix;
    worldNormal = mul(param_2, param_3);
}

static inline __attribute__((always_inline))
float CalcLeavesUVWeight(thread const float2& uvs, thread const float2& uvBounds)
{
    return 1.0;
}

static inline __attribute__((always_inline))
float3 CalcFoliageAnimation(thread const float3& worldPos, thread const float3& localPos, thread const float2& uvs, thread const float& direction, thread const float& time, thread const float& speedLeaves, thread const float& speedBase, thread const float& strengthLeaves, thread const float& strengthBase, thread const float& phase, thread const float& scale, thread const float& cutoff, thread const float& treeHeight, thread const float& treeRadius, thread const float2& uvBounds)
{
    float3 foliageOffsetForward = float3(cos(direction), 0.0, sin(direction));
    float3 foliageOffsetUp = float3(0.0, 1.0, 0.0);
    float4 fastSines = sin((float4(phase) + (float4(1.71717166900634765625, -1.5616161823272705078125, -1.933300018310546875, 1.04166662693023681640625) * (speedLeaves * time))) + ((worldPos.xzzy * scale) * 3.3329999446868896484375));
    float4 slowSines = sin((float4(phase) + (float4(0.533330023288726806640625, -0.01984100043773651123046875, -0.138888895511627197265625, 0.00248015788383781909942626953125) * (speedBase * time))) + (worldPos.xyyx * scale));
    fastSines = (smoothstep(float4(cutoff) + (fastSines * 0.100000001490116119384765625), float4(1.0 - cutoff) - (fastSines.zwyx * 0.100000001490116119384765625), (fastSines * float4(0.5)) + float4(0.5)) * float4(2.0)) - float4(1.0);
    float cutoffBase = cutoff * 0.6665999889373779296875;
    slowSines = (smoothstep(float4(cutoffBase) + (slowSines * 0.100000001490116119384765625), float4(1.0 - cutoffBase) - (slowSines.zwyx * 0.100000001490116119384765625), (slowSines * float4(0.5)) + float4(0.5)) * float4(2.0)) - float4(1.0);
    float leafMask = strengthLeaves * smoothstep(-1.2000000476837158203125, -0.300000011920928955078125, sin(dot(worldPos, foliageOffsetForward) + (speedBase * time)));
    float leafDistance = dot(localPos.xz, localPos.xz);
    float baseMask = smoothstep(0.0, treeHeight, localPos.y);
    float2 blendParamsA = float2(treeRadius * treeRadius, treeRadius);
    float2 blendParamsB = float2(treeRadius, treeRadius * treeRadius);
    float2 blendParams = mix(blendParamsA, blendParamsB, float2(step(1.0, treeRadius)));
    float2 param = uvs;
    float2 param_1 = uvBounds;
    leafMask *= (mix(smoothstep(blendParams.x, blendParams.y, leafDistance), baseMask, baseMask) * CalcLeavesUVWeight(param, param_1));
    baseMask *= strengthBase;
    float4 strengthMask = float4(leafMask, leafMask, baseMask, baseMask);
    return (foliageOffsetForward * dot(strengthMask, float4(fastSines.xy, slowSines.xy))) + (foliageOffsetUp * dot(strengthMask, float4(fastSines.zw, slowSines.zw)));
}

static inline __attribute__((always_inline))
float3 ApplyAmbientLighting(thread const float3& normal, constant float3& g_LightSkylightColor, constant float3& g_LightAmbientColor)
{
    return mix(g_LightSkylightColor, g_LightAmbientColor, float3((dot(normal, float3(0.0, 1.0, 0.0)) * 0.5) + 0.5));
}

vertex main0_out main0(main0_in in [[stage_in]], constant float4x4& g_ModelMatrix [[buffer(0)]], constant float3x3& g_NormalModelMatrix [[buffer(1)]], constant float3& g_LightSkylightColor [[buffer(2)]], constant float3& g_LightAmbientColor [[buffer(3)]], constant float& g_Direction [[buffer(4)]], constant float& g_Time [[buffer(5)]], constant float& g_SpeedLeaves [[buffer(6)]], constant float& g_SpeedBase [[buffer(7)]], constant float& g_StrengthLeaves [[buffer(8)]], constant float& g_StrengthBase [[buffer(9)]], constant float& g_Phase [[buffer(10)]], constant float& g_FoliageScale [[buffer(11)]], constant float& g_CutOff [[buffer(12)]], constant float& g_TreeHeight [[buffer(13)]], constant float& g_TreeRadius [[buffer(14)]], constant float2& g_FoliageUVBounds [[buffer(15)]], constant float4x4& g_ViewProjectionMatrix [[buffer(16)]], constant float3& g_EyePosition [[buffer(17)]])
{
    main0_out out = {};
    float3 localPos = in.a_Position;
    float3 localNormal = in.a_Normal;
    float3 param = localPos;
    float3 param_1 = localNormal;
    float4 param_2;
    float3 param_3;
    ApplyPositionNormal(param, param_1, param_2, param_3, g_ModelMatrix, g_NormalModelMatrix);
    float4 worldPos = param_2;
    float3 worldNormal = param_3;
    float2 leafUVs = float2(1.0);
    float3 param_4 = worldPos.xyz;
    float3 param_5 = localPos;
    float2 param_6 = leafUVs;
    float param_7 = g_Direction;
    float param_8 = g_Time;
    float param_9 = g_SpeedLeaves;
    float param_10 = g_SpeedBase;
    float param_11 = g_StrengthLeaves;
    float param_12 = g_StrengthBase;
    float param_13 = g_Phase;
    float param_14 = g_FoliageScale;
    float param_15 = g_CutOff;
    float param_16 = g_TreeHeight;
    float param_17 = g_TreeRadius;
    float2 param_18 = g_FoliageUVBounds;
    float4 _367 = worldPos;
    float3 _369 = _367.xyz + CalcFoliageAnimation(param_4, param_5, param_6, param_7, param_8, param_9, param_10, param_11, param_12, param_13, param_14, param_15, param_16, param_17, param_18);
    worldPos.x = _369.x;
    worldPos.y = _369.y;
    worldPos.z = _369.z;
    float4 param_19 = worldPos;
    float4x4 param_20 = g_ViewProjectionMatrix;
    out.gl_Position = mul(param_19, param_20);
    out.v_TexCoord = in.a_TexCoord;
    float3 _401 = g_EyePosition - worldPos.xyz;
    out.v_ViewDir.x = _401.x;
    out.v_ViewDir.y = _401.y;
    out.v_ViewDir.z = _401.z;
    out.v_ViewDir.w = worldPos.y;
    float3 param_21 = worldNormal;
    out.v_LightAmbientColor = ApplyAmbientLighting(param_21, g_LightSkylightColor, g_LightAmbientColor);
    return out;
}

