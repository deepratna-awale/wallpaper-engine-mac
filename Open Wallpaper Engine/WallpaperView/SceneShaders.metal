#include <metal_stdlib>
using namespace metal;

struct LayerUniform {
    float2 position;
    float2 size;
    float2 sceneSize;
    float opacity;
    float rotation;
    float4 color;
    float2 uvOrigin;
    float2 uvAxisX;
    float2 uvAxisY;
    float4 effects;
    float blur;
    float4 colorEffects;
    float4 transform;
    float transformScaleY;
};

struct VertexOut {
    float4 position [[position]];
    float2 textureCoordinate;
    float2 sceneCoordinate;
};

struct DXTDecodeUniform {
    uint width;
    uint height;
    uint blockColumns;
    uint format;
};

struct EffectUniform {
    float time;
    float pulse;
};

struct EffectDescriptor {
    uint kind;
    uint maskIndex;
    float4 values;
    float4 extra;
};

float effectMask(uint index, float2 coordinate, texture2d<float> mask0,
                texture2d<float> mask1, texture2d<float> mask2,
                texture2d<float> mask3, sampler maskSampler) {
    if (index == 0) {
        const float4 sample = mask0.sample(maskSampler, coordinate);
        return sample.r;
    }
    if (index == 1) {
        const float4 sample = mask1.sample(maskSampler, coordinate);
        return sample.r;
    }
    if (index == 2) {
        const float4 sample = mask2.sample(maskSampler, coordinate);
        return sample.r;
    }
    if (index == 3) {
        const float4 sample = mask3.sample(maskSampler, coordinate);
        return sample.r;
    }
    return 1.0;
}

float fogNoise(float2 coordinate) {
    float2 cell = floor(coordinate);
    float2 local = fract(coordinate);
    local = local * local * (3.0 - 2.0 * local);
    float a = fract(sin(dot(cell, float2(127.1, 311.7))) * 43758.5453);
    float b = fract(sin(dot(cell + float2(1.0, 0.0), float2(127.1, 311.7))) * 43758.5453);
    float c = fract(sin(dot(cell + float2(0.0, 1.0), float2(127.1, 311.7))) * 43758.5453);
    float d = fract(sin(dot(cell + float2(1.0, 1.0), float2(127.1, 311.7))) * 43758.5453);
    return mix(mix(a, b, local.x), mix(c, d, local.x), local.y);
}

ushort3 color565(ushort value) {
    return ushort3((value >> 11) * 255 / 31, ((value >> 5) & 63) * 255 / 63, (value & 31) * 255 / 31);
}

kernel void decodeDXT(device const uchar *input [[buffer(0)]],
                      texture2d<float, access::write> output [[texture(0)]],
                      constant DXTDecodeUniform &info [[buffer(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= info.width || gid.y >= info.height) return;
    const uint blockIndex = (gid.y / 4) * info.blockColumns + gid.x / 4;
    const uint pixelIndex = (gid.y % 4) * 4 + gid.x % 4;
    const uint offset = blockIndex * (info.format == 7 ? 8 : 16);
    uint alpha = 255;
    uint colorOffset = offset;

    if (info.format == 6) {
        alpha = ((input[offset + pixelIndex / 2] >> ((pixelIndex % 2) * 4)) & 15) * 17;
        colorOffset += 8;
    } else if (info.format == 4) {
        const uint alpha0 = input[offset];
        const uint alpha1 = input[offset + 1];
        ulong alphaBits = 0;
        for (uint index = 0; index < 6; ++index) alphaBits |= ulong(input[offset + 2 + index]) << (index * 8);
        const uint alphaIndex = (alphaBits >> (pixelIndex * 3)) & 7;
        if (alphaIndex == 0) alpha = alpha0;
        else if (alphaIndex == 1) alpha = alpha1;
        else if (alpha0 > alpha1) alpha = ((8 - alphaIndex) * alpha0 + (alphaIndex - 1) * alpha1) / 7;
        else if (alphaIndex < 6) alpha = ((6 - alphaIndex) * alpha0 + (alphaIndex - 1) * alpha1) / 5;
        else alpha = alphaIndex == 6 ? 0 : 255;
        colorOffset += 8;
    }

    const ushort color0 = ushort(input[colorOffset]) | (ushort(input[colorOffset + 1]) << 8);
    const ushort color1 = ushort(input[colorOffset + 2]) | (ushort(input[colorOffset + 3]) << 8);
    const ushort3 first = color565(color0);
    const ushort3 second = color565(color1);
    uint colorBits = uint(input[colorOffset + 4]) | (uint(input[colorOffset + 5]) << 8)
        | (uint(input[colorOffset + 6]) << 16) | (uint(input[colorOffset + 7]) << 24);
    const uint colorIndex = (colorBits >> (pixelIndex * 2)) & 3;
    ushort3 color;
    if (colorIndex == 0) color = first;
    else if (colorIndex == 1) color = second;
    else if (colorIndex == 2) color = (info.format == 7 && color0 <= color1) ? (first + second) / 2 : (2 * first + second) / 3;
    else if (info.format == 7 && color0 <= color1) { color = ushort3(0); alpha = 0; }
    else color = (first + 2 * second) / 3;
    output.write(float4(float(color.x) / 255.0, float(color.y) / 255.0,
                        float(color.z) / 255.0, float(alpha) / 255.0), gid);
}

vertex VertexOut sceneVertex(uint vertexID [[vertex_id]], constant LayerUniform &layer [[buffer(0)]],
                             constant EffectUniform &effect [[buffer(1)]],
                             constant EffectDescriptor *effects [[buffer(2)]],
                             constant uint &effectCount [[buffer(3)]]) {
    constexpr float2 corners[] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
    const float2 local = (corners[vertexID] - 0.5) * layer.size;
    const float2 rotated = float2(local.x * cos(layer.rotation) - local.y * sin(layer.rotation),
                                  local.x * sin(layer.rotation) + local.y * cos(layer.rotation));
    const float2 point = float2(layer.position.x, layer.sceneSize.y - layer.position.y) + rotated;
    VertexOut out;
    out.position = float4(point.x / layer.sceneSize.x * 2 - 1, 1 - point.y / layer.sceneSize.y * 2, 0, 1);
    out.textureCoordinate = layer.uvOrigin + corners[vertexID].x * layer.uvAxisX + corners[vertexID].y * layer.uvAxisY;
    out.sceneCoordinate = point / layer.sceneSize;
    return out;
}

fragment float4 sceneFragment(VertexOut input [[stage_in]], texture2d<float> texture [[texture(0)]],
                              constant LayerUniform &layer [[buffer(0)]],
                              constant EffectUniform &effect [[buffer(1)]],
                              constant EffectDescriptor *effects [[buffer(2)]],
                              constant uint &effectCount [[buffer(3)]],
                              texture2d<float> mask0 [[texture(1)]], texture2d<float> mask1 [[texture(2)]],
                              texture2d<float> mask2 [[texture(3)]], texture2d<float> mask3 [[texture(4)]]) {
    constexpr sampler linearSampler(filter::linear);
    float2 coordinate = input.textureCoordinate;
    coordinate = (coordinate - 0.5) / max(float2(layer.transform.w, layer.transformScaleY), 0.001) + 0.5;
    const float transformCos = cos(layer.transform.x);
    const float transformSin = sin(layer.transform.x);
    coordinate = float2(coordinate.x * transformCos - coordinate.y * transformSin,
                        coordinate.x * transformSin + coordinate.y * transformCos);
    coordinate += layer.transform.yz;
    const float2 maskCoordinate = float2(input.sceneCoordinate.x, 1.0 - input.sceneCoordinate.y);
    for (uint index = 0; index < effectCount; ++index) {
        const EffectDescriptor descriptor = effects[index];
        const float mask = effectMask(descriptor.maskIndex, maskCoordinate, mask0, mask1, mask2, mask3, linearSampler);
        if (descriptor.kind == 1) {
            const float phase = effect.time * descriptor.values.y;
            float shake = sin(phase);
            shake = sign(shake) * pow(abs(max(0.00001, shake)), descriptor.values.z);
            shake += descriptor.values.w;
            coordinate += (shake * 2.0 - 1.0) * descriptor.values.x * descriptor.values.x * mask;
        } else if (descriptor.kind == 2) {
            const float2 direction = float2(-sin(descriptor.values.w), cos(descriptor.values.w));
            const float2 offset = float2(direction.y, -direction.x);
            const float distance = effect.time * descriptor.values.y + dot(coordinate, direction) * descriptor.values.z;
            const float wave = sign(sin(distance)) * pow(abs(sin(distance)), descriptor.extra.x);
            coordinate += offset * wave * descriptor.values.x * descriptor.values.x * mask;
        } else if (descriptor.kind == 4) {
            const float dblend = sign(sin(effect.time)) * pow(abs(max(0.00001, sin(effect.time))), 4.0);
            const float distortion = dblend * descriptor.values.w * 0.02
                * smoothstep(0.01 * descriptor.extra.y, 0.0, abs(fract(effect.time * descriptor.extra.x) - coordinate.y));
            coordinate.x += distortion * descriptor.values.x * mask;
        } else if (descriptor.kind == 6) {
            coordinate += (coordinate - 0.5) * sin(effect.time * 1.5) * 0.01 * mask;
        }
    }
    float4 color = texture.sample(linearSampler, coordinate);
    for (uint index = 0; index < effectCount; ++index) {
        const EffectDescriptor descriptor = effects[index];
        const float mask = effectMask(descriptor.maskIndex, maskCoordinate, mask0, mask1, mask2, mask3, linearSampler);
        if (descriptor.kind == 7) {
            float volume = 0.0;
            const float depth = clamp(1.0 - input.sceneCoordinate.y, 0.0, 1.0);
            for (int sampleIndex = 0; sampleIndex < 7; ++sampleIndex) {
                const float layer = float(sampleIndex) - 3.0;
                const float2 sampleCoordinate = clamp(coordinate
                    + float2(layer * 0.012, layer * 0.004), 0.001, 0.999);
                const float sampleAlpha = texture.sample(linearSampler, sampleCoordinate).a;
                const float noise = fogNoise(sampleCoordinate * 3.5 + effect.time * descriptor.values.y);
                volume += sampleAlpha * mix(0.72, 1.0, noise);
            }
            volume = clamp(volume / 7.0 * descriptor.values.x, 0.0, 1.0);
            const float depthFade = smoothstep(descriptor.extra.x, descriptor.extra.y, depth);
            const float fogAmount = volume * depthFade * mask;
            const float3 fogColor = mix(float3(0.74, 0.79, 0.84), float3(0.94, 0.96, 0.98), depth);
            color.rgb = mix(color.rgb, fogColor, fogAmount * 0.42);
            color.a = max(color.a, fogAmount * 0.65);
        } else if (descriptor.kind == 3) {
            const float aspect = layer.size.x / max(layer.size.y, 1.0);
            const float2 base = coordinate * float2(aspect, 1.0);
            const float2 noise0 = base * descriptor.extra.y + effect.time * descriptor.values.yz;
            const float2 noise1 = float2(-base.y, base.x) * descriptor.extra.z
                + effect.time * float2(descriptor.values.w, descriptor.extra.x);
            const float nitro0 = 0.5 + 0.5 * sin(dot(noise0, float2(17.0, 31.0)));
            const float nitro1 = 0.5 + 0.5 * sin(dot(noise1, float2(23.0, 13.0)));
            const float product = nitro0 * nitro1;
            const float bounds = descriptor.extra.w;
            const float glow = smoothstep(0.25, bounds, product) * smoothstep(bounds, 0.25, product) * 4.0 * mask;
            const float3 nitroColor = mix(float3(0.247, 0.478, 0.682), float3(0.376, 0.568, 0.745), glow);
            color.rgb = mix(color.rgb, nitroColor, glow * descriptor.values.x);
        } else if (descriptor.kind == 4) {
            const float aspect = layer.size.x / max(layer.size.y, 1.0);
            const float2 noiseCoordinate = coordinate * float2(aspect, 1.0);
            const float3 glitchOffset = descriptor.values.y
                * smoothstep(0.0, 2.0, 1.0 + 0.5 * sin(effect.time * float3(22.0, 14.0, 26.0)))
                * float3(0.0019, 0.0021, 0.0017);
            const float chromatic = descriptor.values.y;
            color.r = texture.sample(linearSampler, coordinate + float2(0.005, -0.0005) * chromatic + float2(glitchOffset.x, 0)).r;
            color.b = texture.sample(linearSampler, coordinate + float2(-0.006, -0.0045) * chromatic - float2(glitchOffset.z, 0)).b;
            const float artifact = sin(noiseCoordinate.x * 10.0 + effect.time * 6.0)
                * sin(noiseCoordinate.y * 20.0 - effect.time * 3.0) * descriptor.values.z;
            color.rgb += artifact * 0.04 * mask;
        }
    }
    color.rgb *= 1.0 + effect.pulse * 0.35;
    const float blur = max(layer.blur, 0.0) * 0.002;
    if (blur > 0.0) {
        color = (color + texture.sample(linearSampler, coordinate + float2(blur, 0))
            + texture.sample(linearSampler, coordinate - float2(blur, 0))
            + texture.sample(linearSampler, coordinate + float2(0, blur))
            + texture.sample(linearSampler, coordinate - float2(0, blur))) / 5.0;
    }
    color.rgb *= exp2(layer.colorEffects.x);
    color.rgb = (color.rgb - 0.5) * max(layer.effects.y, 0.0) + 0.5;
    const float luminance = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
    color.rgb = mix(float3(luminance), color.rgb, max(layer.effects.z, 0.0));
    const float angle = layer.colorEffects.z;
    if (abs(angle) > 0.0001) {
        const float y = dot(color.rgb, float3(0.299, 0.587, 0.114));
        const float i = dot(color.rgb, float3(0.596, -0.275, -0.321));
        const float q = dot(color.rgb, float3(0.212, -0.523, 0.311));
        const float rotatedI = i * cos(angle) - q * sin(angle);
        const float rotatedQ = i * sin(angle) + q * cos(angle);
        color.rgb = float3(y + 0.956 * rotatedI + 0.621 * rotatedQ,
                           y - 0.272 * rotatedI - 0.647 * rotatedQ,
                           y - 1.106 * rotatedI + 1.703 * rotatedQ);
    }
    color.rgb = pow(max(color.rgb, 0.0), float3(1.0 / max(layer.colorEffects.y, 0.001)));
    color.rgb *= max(layer.effects.x, 0.0) * (1.0 + effect.pulse * 0.35);
    color.rgb += max(color.rgb - layer.colorEffects.w, 0.0) * max(layer.effects.w, 0.0);
    return color * layer.opacity * layer.color;
}