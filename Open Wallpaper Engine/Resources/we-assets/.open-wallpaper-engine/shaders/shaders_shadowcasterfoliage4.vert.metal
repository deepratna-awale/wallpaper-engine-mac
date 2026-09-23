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
    uint we_ViewportIndex [[user(locn0)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
};

static inline __attribute__((always_inline))
float4 mul(thread const float4& value, thread const float4x4& matrix)
{
    return matrix * value;
}

static inline __attribute__((always_inline))
void ApplyPosition(thread const float3& position, thread float4& worldPosition, constant float4x4& g_ModelMatrix)
{
    float4 param = float4(position, 1.0);
    float4x4 param_1 = g_ModelMatrix;
    worldPosition = mul(param, param_1);
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

vertex main0_out main0(main0_in in [[stage_in]], constant float4x4& g_ModelMatrix [[buffer(0)]], constant float& g_Direction [[buffer(1)]], constant float& g_Time [[buffer(2)]], constant float& g_SpeedLeaves [[buffer(3)]], constant float& g_SpeedBase [[buffer(4)]], constant float& g_StrengthLeaves [[buffer(5)]], constant float& g_StrengthBase [[buffer(6)]], constant float& g_Phase [[buffer(7)]], constant float& g_FoliageScale [[buffer(8)]], constant float& g_CutOff [[buffer(9)]], constant float& g_TreeHeight [[buffer(10)]], constant float& g_TreeRadius [[buffer(11)]], constant float2& g_FoliageUVBounds [[buffer(12)]], constant spvUnsafeArray<float4x4, 6>& g_ViewportViewProjectionMatrices [[buffer(13)]], uint gl_InstanceID [[instance_id]])
{
    main0_out out = {};
    float3 localPos = in.a_Position;
    float3 param = localPos;
    float4 param_1;
    ApplyPosition(param, param_1, g_ModelMatrix);
    float4 worldPos = param_1;
    float2 leafUVs = float2(1.0);
    float3 param_2 = worldPos.xyz;
    float3 param_3 = localPos;
    float2 param_4 = leafUVs;
    float param_5 = g_Direction;
    float param_6 = g_Time;
    float param_7 = g_SpeedLeaves;
    float param_8 = g_SpeedBase;
    float param_9 = g_StrengthLeaves;
    float param_10 = g_StrengthBase;
    float param_11 = g_Phase;
    float param_12 = g_FoliageScale;
    float param_13 = g_CutOff;
    float param_14 = g_TreeHeight;
    float param_15 = g_TreeRadius;
    float2 param_16 = g_FoliageUVBounds;
    float4 _321 = worldPos;
    float3 _323 = _321.xyz + CalcFoliageAnimation(param_2, param_3, param_4, param_5, param_6, param_7, param_8, param_9, param_10, param_11, param_12, param_13, param_14, param_15, param_16);
    worldPos.x = _323.x;
    worldPos.y = _323.y;
    worldPos.z = _323.z;
    float4 param_17 = worldPos;
    float4x4 param_18 = g_ViewportViewProjectionMatrices[gl_InstanceID];
    out.gl_Position = mul(param_17, param_18);
    out.we_ViewportIndex = uint(gl_InstanceID);
    return out;
}

