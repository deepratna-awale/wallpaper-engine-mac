#include <metal_stdlib>
using namespace metal;

// Strength/intensity values are authored (and shown in our UI) at the wallpaper's natural
// scale (e.g. 0.4); our shaders visually need roughly 1/10th that magnitude to look correct.
constant float kAuthoredMagnitudeScale = 0.01;

struct LayerUniform {
    float2 position;
    float2 size;
    float2 sceneSize;
    float opacity;
    float particleShape;
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
    float4 bloomTint;
};

struct VertexOut {
    float4 position [[position]];
    float2 textureCoordinate;
    float2 sceneCoordinate;
    // Particles are drawn as one instanced call per system; the fragment stage indexes the same
    // uniform array, so the index must not be interpolated.
    uint instance [[flat]];
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
    float2 cursor;
    float4 audioBands0;
    float4 audioBands1;
    float4 audioBands2;
    float4 audioBands3;
};

struct EffectDescriptor {
    uint kind;
    uint maskIndex;
    float4 values;
    float4 extra;
    float4 extra2;
    float4 extra3;
};

float4 effectSlotColor(uint index, float2 coordinate, texture2d<float> mask0,
                       texture2d<float> mask1, texture2d<float> mask2,
                       texture2d<float> mask3, sampler maskSampler) {
    if (index == 0) { return mask0.sample(maskSampler, coordinate); }
    if (index == 1) { return mask1.sample(maskSampler, coordinate); }
    if (index == 2) { return mask2.sample(maskSampler, coordinate); }
    if (index == 3) { return mask3.sample(maskSampler, coordinate); }
    return float4(0.0);
}

static float3 rgbToHsl(float3 color) {
    const float maxC = max(color.r, max(color.g, color.b));
    const float minC = min(color.r, min(color.g, color.b));
    const float lightness = (maxC + minC) * 0.5;
    const float delta = maxC - minC;
    if (delta < 1e-5) { return float3(0.0, 0.0, lightness); }
    const float saturation = lightness > 0.5 ? delta / (2.0 - maxC - minC) : delta / (maxC + minC);
    float hue;
    if (maxC == color.r) { hue = (color.g - color.b) / delta + (color.g < color.b ? 6.0 : 0.0); }
    else if (maxC == color.g) { hue = (color.b - color.r) / delta + 2.0; }
    else { hue = (color.r - color.g) / delta + 4.0; }
    return float3(hue / 6.0, saturation, lightness);
}

static float hueToChannel(float p, float q, float t) {
    if (t < 0.0) { t += 1.0; }
    if (t > 1.0) { t -= 1.0; }
    if (t < 1.0 / 6.0) { return p + (q - p) * 6.0 * t; }
    if (t < 0.5) { return q; }
    if (t < 2.0 / 3.0) { return p + (q - p) * (2.0 / 3.0 - t) * 6.0; }
    return p;
}

static float3 hslToRgb(float3 hsl) {
    if (hsl.y < 1e-5) { return float3(hsl.z); }
    const float q = hsl.z < 0.5 ? hsl.z * (1.0 + hsl.y) : hsl.z + hsl.y - hsl.z * hsl.y;
    const float p = 2.0 * hsl.z - q;
    return float3(hueToChannel(p, q, hsl.x + 1.0 / 3.0),
                  hueToChannel(p, q, hsl.x),
                  hueToChannel(p, q, hsl.x - 1.0 / 3.0));
}

/// Wallpaper Engine's `ApplyBlending` from common_blending.h. Mode indices match the BLENDMODE
/// combo the editor writes, so an authored value maps straight through.
static float3 applyBlending(int mode, float3 A, float3 B, float opacity) {
    float3 result;
    switch (mode) {
        case 1:  result = min(A, B); break;                                        // darken
        case 2:  result = A * B; break;                                            // multiply
        case 3:  result = 1.0 - min(float3(1.0), (1.0 - A) / max(B, 1e-4)); break;  // color burn
        case 4:  result = max(A + B - 1.0, 0.0); break;                            // linear burn
        case 5:  return min(A, B);
        case 6:  result = max(A, B); break;                                        // lighten
        case 7:  result = 1.0 - (1.0 - A) * (1.0 - B); break;                      // screen
        case 8:  result = min(A / max(1.0 - B, 1e-4), 1.0); break;                 // color dodge
        case 9:  result = min(A + B, 1.0); break;                                  // linear dodge
        case 10: return max(A, B);
        case 11: result = select(2.0 * A * B, 1.0 - 2.0 * (1.0 - A) * (1.0 - B), A > 0.5); break;
        case 12: result = select(2.0 * A * B + A * A * (1.0 - 2.0 * B),
                                 sqrt(A) * (2.0 * B - 1.0) + 2.0 * A * (1.0 - B), B > 0.5); break;
        case 13: result = select(2.0 * A * B, 1.0 - 2.0 * (1.0 - A) * (1.0 - B), B > 0.5); break;
        case 14: result = select(1.0 - min((1.0 - A) / max(2.0 * B, 1e-4), 1.0),
                                 min(A / max(2.0 * (1.0 - B), 1e-4), 1.0), B > 0.5); break;
        case 15: result = clamp(2.0 * B + A - 1.0, 0.0, 1.0); break;               // linear light
        case 16: result = select(min(A, 2.0 * B), max(A, 2.0 * B - 1.0), B > 0.5); break;
        case 17: result = step(1.0, A + B); break;                                 // hard mix
        case 18: result = abs(A - B); break;                                       // difference
        case 19: result = A + B - 2.0 * A * B; break;                              // exclusion
        case 20: result = max(A - B, 0.0); break;                                  // subtract
        case 21: result = select(min(A * A / max(1.0 - B, 1e-4), 1.0), float3(1.0), B >= 1.0); break;
        case 22: result = select(min(B * B / max(1.0 - A, 1e-4), 1.0), float3(1.0), A >= 1.0); break;
        case 23: result = min(A, B) - max(A, B) + 1.0; break;                      // phoenix
        case 24: result = (A + B) * 0.5; break;                                    // average
        case 25: result = 1.0 - abs(1.0 - A - B); break;                           // negation
        case 26: result = hslToRgb(float3(rgbToHsl(B).r, rgbToHsl(A).g, rgbToHsl(A).b)); break;
        case 27: result = hslToRgb(float3(rgbToHsl(A).r, rgbToHsl(B).g, rgbToHsl(A).b)); break;
        case 28: { const float3 bHsl = rgbToHsl(B);
                   result = hslToRgb(float3(bHsl.r, bHsl.g, rgbToHsl(A).b)); } break;
        case 29: { const float3 aHsl = rgbToHsl(A);
                   result = hslToRgb(float3(aHsl.r, aHsl.g, rgbToHsl(B).b)); } break;
        case 30: result = A * B + A * (1.0 - B); break;                            // tint
        case 31: return A + B * opacity;
        case 32: result = A + A * B; break;
        default: result = B; break;                                                // normal
    }
    return mix(A, result, opacity);
}

float effectMask(uint index, float2 coordinate, texture2d<float> mask0,
                texture2d<float> mask1, texture2d<float> mask2,
                texture2d<float> mask3, sampler maskSampler) {
    if (index == 0) {
        const float4 sample = mask0.sample(maskSampler, coordinate);
        return sample.a < 0.999 ? sample.a : sample.r;
    }
    if (index == 1) {
        const float4 sample = mask1.sample(maskSampler, coordinate);
        return sample.a < 0.999 ? sample.a : sample.r;
    }
    if (index == 2) {
        const float4 sample = mask2.sample(maskSampler, coordinate);
        return sample.a < 0.999 ? sample.a : sample.r;
    }
    if (index == 3) {
        const float4 sample = mask3.sample(maskSampler, coordinate);
        return sample.a < 0.999 ? sample.a : sample.r;
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

float audioBandValue(constant EffectUniform &effect, int index) {
    if (index < 4) return effect.audioBands0[index];
    if (index < 8) return effect.audioBands1[index - 4];
    if (index < 12) return effect.audioBands2[index - 8];
    return effect.audioBands3[index - 12];
}

float audioRangeResponse(constant EffectUniform &effect, float minBand, float maxBand, float2 bounds, float power, float multiply) {
    const int firstBand = int(clamp(floor(minBand), 0.0, 15.0));
    const int lastBand = int(clamp(floor(max(maxBand, minBand)), 0.0, 15.0));
    float response = 0.0;
    for (int band = 0; band < 16; ++band) {
        if (band >= firstBand && band <= lastBand) {
            response += audioBandValue(effect, band);
        }
    }
    response /= float(max(lastBand - firstBand + 1, 1));
    response = smoothstep(bounds.x, bounds.y, response);
    return saturate(pow(max(response, 0.0), max(power, 0.001)) * multiply);
}

float3 hueRotate(float3 color, float angle) {
    const float s = sin(angle);
    const float c = cos(angle);
    const float3 weights = float3(0.299, 0.587, 0.114);
    return color * c + cross(weights, color) * s + weights * dot(weights, color) * (1.0 - c);
}

float4 gaussianBlur5(texture2d<float> texture, sampler samplerState, float2 coordinate, float radius) {
    const float centerWeight = 0.227027;
    const float nearWeight = 0.316216;
    const float farWeight = 0.070270;
    float4 result = texture.sample(samplerState, coordinate) * centerWeight;
    result += texture.sample(samplerState, coordinate + float2(radius, 0)) * nearWeight;
    result += texture.sample(samplerState, coordinate - float2(radius, 0)) * nearWeight;
    result += texture.sample(samplerState, coordinate + float2(radius * 2.0, 0)) * farWeight;
    result += texture.sample(samplerState, coordinate - float2(radius * 2.0, 0)) * farWeight;
    return result;
}

float4 gaussianBlurPrecise(texture2d<float> texture, sampler samplerState, float2 coordinate, float radius) {
    const float centerWeight = 0.25;
    const float axisWeight = 0.125;
    const float diagonalWeight = 0.0625;
    float4 result = texture.sample(samplerState, coordinate) * centerWeight;
    const float2 axisX = float2(radius, 0);
    const float2 axisY = float2(0, radius);
    const float2 diagonal = float2(radius, radius);
    result += texture.sample(samplerState, coordinate + axisX) * axisWeight;
    result += texture.sample(samplerState, coordinate - axisX) * axisWeight;
    result += texture.sample(samplerState, coordinate + axisY) * axisWeight;
    result += texture.sample(samplerState, coordinate - axisY) * axisWeight;
    result += texture.sample(samplerState, coordinate + diagonal) * diagonalWeight;
    result += texture.sample(samplerState, coordinate - diagonal) * diagonalWeight;
    result += texture.sample(samplerState, coordinate + float2(radius, -radius)) * diagonalWeight;
    result += texture.sample(samplerState, coordinate + float2(-radius, radius)) * diagonalWeight;
    return result;
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

vertex VertexOut sceneVertex(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                             uint baseInstance [[base_instance]],
                             constant LayerUniform *layers [[buffer(0)]],
                             constant EffectUniform &effect [[buffer(1)]],
                             constant EffectDescriptor *effects [[buffer(2)]],
                             constant uint &effectCount [[buffer(3)]]) {
    const uint instance = instanceID + baseInstance;
    const LayerUniform layer = layers[instance];
    constexpr float2 corners[] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
    const float2 local = (corners[vertexID] - 0.5) * layer.size;
    const float2 rotated = float2(local.x * cos(layer.rotation) - local.y * sin(layer.rotation),
                                  local.x * sin(layer.rotation) + local.y * cos(layer.rotation));
    const float2 point = float2(layer.position.x, layer.sceneSize.y - layer.position.y) + rotated;
    VertexOut out;
    out.position = float4(point.x / layer.sceneSize.x * 2 - 1, 1 - point.y / layer.sceneSize.y * 2, 0, 1);
    out.textureCoordinate = layer.uvOrigin + corners[vertexID].x * layer.uvAxisX + corners[vertexID].y * layer.uvAxisY;
    out.sceneCoordinate = point / layer.sceneSize;
    out.instance = instance;
    return out;
}

fragment float4 sceneFragment(VertexOut input [[stage_in]], texture2d<float> texture [[texture(0)]],
                              constant LayerUniform *layers [[buffer(0)]],
                              constant EffectUniform &effect [[buffer(1)]],
                              constant EffectDescriptor *effects [[buffer(2)]],
                              constant uint &effectCount [[buffer(3)]],
                              texture2d<float> mask0 [[texture(1)]], texture2d<float> mask1 [[texture(2)]],
                              texture2d<float> mask2 [[texture(3)]], texture2d<float> mask3 [[texture(4)]],
                              texture2d<float> xrayTexture [[texture(5)]]) {
    const LayerUniform layer = layers[input.instance];
    constexpr sampler linearSampler(filter::linear);
    float2 coordinate = input.textureCoordinate;
    if (layer.particleShape > 0.5 && distance(coordinate, float2(0.5)) > 0.5) {
        discard_fragment();
    }
    coordinate = (coordinate - 0.5) / max(float2(layer.transform.w, layer.transformScaleY), 0.001) + 0.5;
    const float transformCos = cos(layer.transform.x);
    const float transformSin = sin(layer.transform.x);
    coordinate = float2(coordinate.x * transformCos - coordinate.y * transformSin,
                        coordinate.x * transformSin + coordinate.y * transformCos);
    coordinate += layer.transform.yz;
    // Masks are authored against the layer's own texture UV, not the whole scene canvas, so they
    // must be sampled at the (undistorted) local coordinate rather than a scene-wide one.
    const float2 maskCoordinate = coordinate;
    for (uint index = 0; index < effectCount; ++index) {
        const EffectDescriptor descriptor = effects[index];
        const float mask = effectMask(descriptor.maskIndex, maskCoordinate, mask0, mask1, mask2, mask3, linearSampler);
        if (descriptor.kind == 14) {
            constexpr float pi = 3.14159265358979323846;
            const float aperture = 178.0 * (pi / 180.0);
            const float maxFactor = sin(0.5 * aperture);
            const float2 center = descriptor.values.zw;
            const float size = max(descriptor.values.x, 0.01);
            const float2 xy = (coordinate - center) * 2.0 / size;
            const float distance = length(xy);
            if (distance < 2.0 - maxFactor) {
                const float scaledDistance = length(xy * maxFactor);
                const float radius = atan2(scaledDistance, sqrt(max(1.0 - scaledDistance * scaledDistance, 0.0))) / pi;
                const float angle = atan2(xy.y, xy.x);
                const float2 warped = radius * float2(cos(angle), sin(angle)) * size + center;
                coordinate = mix(coordinate, warped, descriptor.values.y) * mask + coordinate * (1.0 - mask);
            }
        } else if (descriptor.kind == 15) {
            const float2 speed = float2(descriptor.values.x, descriptor.values.y);
            const float2 offset = sign(speed) * pow(abs(speed), float2(2.0)) * effect.time;
            coordinate = fract((coordinate + offset) * max(descriptor.values.zw, 0.01));
        } else if (descriptor.kind == 23 || descriptor.kind == 24 || descriptor.kind == 34) {
            const float phase = effect.time * descriptor.values.y;
            const float2 flow = float2(sin(phase), cos(phase)) * descriptor.values.x;
            coordinate += flow * float2(1.0, 0.65) * mask;
        } else if (descriptor.kind == 28) {
            const float2 centered = coordinate - 0.5;
            coordinate = 0.5 + centered / max(1.0 - descriptor.values.x * length(centered), 0.2) * mask;
        } else if (descriptor.kind == 30) {
            coordinate.x += (coordinate.y - 0.5) * descriptor.values.x * sin(effect.time * descriptor.values.y) * mask;
        } else if (descriptor.kind == 31) {
            coordinate.x += sin(effect.time * descriptor.values.y + coordinate.y * 6.2831853) * descriptor.values.x * mask;
        } else if (descriptor.kind == 33) {
            const float2 delta = coordinate - descriptor.values.zw;
            const float angle = descriptor.values.x * sin(effect.time * descriptor.values.y) * (1.0 - length(delta));
            const float s = sin(angle);
            const float c = cos(angle);
            coordinate = descriptor.values.zw + float2(delta.x * c - delta.y * s, delta.x * s + delta.y * c) * mask + delta * (1.0 - mask);
        } else if (descriptor.kind == 38 || descriptor.kind == 42) {
            const float phase = effect.time * descriptor.values.y;
            const float2 centered = coordinate - 0.5;
            const float distance = length(centered);
            const float ripple = sin(distance * 36.0 - phase * 4.0) * descriptor.values.x;
            coordinate += normalize(centered + 0.0001) * ripple * mask;
        } else if (descriptor.kind == 46) {
            const float depth = effectMask(descriptor.maskIndex, maskCoordinate, mask0, mask1, mask2, mask3, linearSampler);
            const float centeredDepth = depth - 0.5;
            const float2 displacement = effect.cursor * centeredDepth
                * float2(descriptor.values.x, descriptor.values.y) * mask;
            coordinate += displacement;
            const float perspective = max(descriptor.values.z, 0.0) * centeredDepth * length(effect.cursor);
            const float2 centered = coordinate - descriptor.extra.xy;
            coordinate = descriptor.extra.xy + centered / max(1.0 + perspective, 0.05);
        } else if (descriptor.kind == 49) {
            const float response = audioRangeResponse(effect, descriptor.values.z, descriptor.values.w,
                                                      descriptor.extra.xy, descriptor.values.y, descriptor.values.x);
            const float2 centered = coordinate - 0.5;
            const float distance = length(centered);
            const float warp = response * descriptor.extra.z;
            coordinate = 0.5 + centered / max(1.0 + warp * (1.0 + distance * 2.5), 0.15);
            coordinate += normalize(centered + 0.0001) * sin(distance * 48.0 - effect.time * (4.0 + descriptor.extra.w * 6.0)) * response * 0.018 * mask;
        } else if (descriptor.kind == 6) {
            // Iris-follow-cursor: the authored mask identifies only the iris
            // pixels. Move the sampled iris texture toward the cursor while
            // keeping the eyelid/eye layer fixed and limiting eye travel.
            const float2 look = float2(effect.cursor.x, -effect.cursor.y);
            const float lookLength = length(look);
            const float2 lookDirection = lookLength > 0.0001 ? look / lookLength : float2(0.0);
            const float travel = smoothstep(0.015, 0.5, min(lookLength, 0.5)) * 0.075 * descriptor.values.x;
            const float2 irisOffset = lookDirection * travel;
            coordinate += irisOffset * mask;
        } else if (descriptor.kind == 1) {
            const float phase = effect.time * descriptor.values.y;
            const float step = floor(phase);
            const float blend = smoothstep(0.0, 1.0, fract(phase));
            const float2 randomA = fract(sin(float2(step * 12.9898 + 78.233,
                                                   step * 39.346 + 11.135)) * 43758.5453) * 2.0 - 1.0;
            const float nextStep = step + 1.0;
            const float2 randomB = fract(sin(float2(nextStep * 12.9898 + 78.233,
                                                   nextStep * 39.346 + 11.135)) * 43758.5453) * 2.0 - 1.0;
            float2 shake = mix(randomA, randomB, blend);
            shake = sign(shake) * pow(max(abs(shake), 0.00001), float2(max(descriptor.values.z, 0.01)));
            const float authoredStrength = descriptor.values.x * kAuthoredMagnitudeScale;
            const float amplitude = authoredStrength * authoredStrength * (1.0 + descriptor.values.w * 0.35);
            coordinate += shake * amplitude * mask;
        } else if (descriptor.kind == 2) {
            const float2 direction = float2(-sin(descriptor.values.w), cos(descriptor.values.w));
            const float2 offset = float2(direction.y, -direction.x);
            const float distance = effect.time * descriptor.values.y + dot(coordinate, direction) * descriptor.values.z;
            const float wave = sign(sin(distance)) * pow(abs(sin(distance)), descriptor.extra.x);
            coordinate += offset * wave * (descriptor.values.x * kAuthoredMagnitudeScale) * mask;
        } else if (descriptor.kind == 4) {
            const float dblend = sign(sin(effect.time)) * pow(abs(max(0.00001, sin(effect.time))), 4.0);
            const float distortion = dblend * (descriptor.values.w * kAuthoredMagnitudeScale) * 0.02
                * smoothstep(0.01 * descriptor.extra.y, 0.0, abs(fract(effect.time * descriptor.extra.x) - coordinate.y));
            coordinate.x += distortion * (descriptor.values.x * kAuthoredMagnitudeScale) * mask;
        } else if (descriptor.kind == 8) {
            const float sway = sin(coordinate.y * (10.0 + descriptor.extra.y * 20.0) + effect.time * descriptor.values.z + descriptor.values.w * 6.2831853);
            const float shaped = sign(sway) * pow(abs(sway), max(descriptor.extra.x, 0.01));
            coordinate.x += shaped * (descriptor.values.x * kAuthoredMagnitudeScale) * descriptor.values.y * mask;
        } else if (descriptor.kind == 9) {
            const float2 direction = float2(cos(descriptor.values.w), sin(descriptor.values.w));
            const float2 normal = float2(-direction.y, direction.x);
            const float phase = dot(coordinate, direction) * (descriptor.values.y * 12.0)
                - effect.time * (descriptor.values.z * 6.0 + descriptor.extra.x);
            coordinate += normal * sin(phase) * (descriptor.values.x * kAuthoredMagnitudeScale) * mask;
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
        } else if (descriptor.kind == 6) {
            // Iris movement is applied in the coordinate pass above.
        } else if (descriptor.kind == 3) {
            const float aspect = layer.size.x / max(layer.size.y, 1.0);
            const float2 base = coordinate * float2(aspect, 1.0);
            const float2 noise0 = base * descriptor.extra.y + effect.time * descriptor.values.yz;
            const float2 noise1 = float2(-base.y, base.x) * descriptor.extra.z
                + effect.time * float2(descriptor.values.w, descriptor.extra.x);
            const float nitro0 = 0.5 + 0.5 * sin(dot(noise0, float2(17.0, 31.0)));
            const float nitro1 = 0.5 + 0.5 * sin(dot(noise1, float2(23.0, 13.0)));
            const float product = nitro0 * nitro1;
            const float boundsHigh = descriptor.extra.w;
            const float boundsLow = descriptor.extra3.w;
            const float smoothness = max(descriptor.extra2.w, 0.05);
            const float glow = smoothstep(boundsLow, boundsHigh, product) * smoothstep(boundsHigh, boundsLow, product) * (4.0 / smoothness) * mask;
            const float3 nitroColor = mix(descriptor.extra2.xyz, descriptor.extra3.xyz, saturate(glow));
            color.rgb = mix(color.rgb, nitroColor, saturate(glow * descriptor.values.x));
        } else if (descriptor.kind == 10) {
            if (descriptor.values.y <= 0.0001) { continue; }
            // The host layer is the authored rectangular light source. Its width and
            // height arrive through layer.size and therefore remain editable/scriptable.
            const float2 local = coordinate;
            const float2 centered = (local - 0.5) * float2(layer.size.x / max(layer.size.y, 1.0), 1.0);
            const float distanceFromSource = clamp(local.y, 0.0, 1.0);
            const float noise = fogNoise(float2(centered.x, distanceFromSource) * descriptor.extra.y * 2.0
                                         + effect.time * descriptor.values.w * 0.35);
            const float beamWidth = max(0.08, 0.18 + descriptor.values.x * 0.42);
            const float beam = exp(-pow(centered.x / beamWidth, 2.0) * 1.6);
            const float secondaryBeam = exp(-pow((centered.x + sin(effect.time * 0.25) * 0.18) / (beamWidth * 2.2), 2.0) * 1.6);
            const float edge = 1.0 - smoothstep(0.45, 0.5, abs(local.x - 0.5));
            const float falloff = pow(1.0 - distanceFromSource, 0.72) * edge;
            const float lightVolume = (beam * 0.72 + secondaryBeam * 0.28) * (0.82 + noise * 0.18);
            const float intensity = lightVolume * falloff * (descriptor.values.y * kAuthoredMagnitudeScale) * mask;
            color.rgb += intensity * float3(1.0, 0.88, 0.68);
            color.a = max(color.a, intensity);
        } else if (descriptor.kind == 11) {
            if (descriptor.extra.y <= 0.0001) { continue; }
            // A light-shaft source is a rectangle; widening its layer changes the
            // source width, while its height controls the available cone length.
            const float2 local = coordinate;
            const float depth = clamp(local.y, 0.0, 1.0);
            const float coneWidth = mix(0.045, 0.95, depth);
            const float coneDistance = abs(local.x - 0.5);
            const float cone = 1.0 - smoothstep(coneWidth * 0.5, coneWidth * 0.5 + 0.12, coneDistance);
            const float noise = fogNoise(float2(local.x, depth) * descriptor.extra.x * 3.0
                                         + effect.time * descriptor.values.y * 0.3);
            const float softBeam = exp(-pow((local.x - 0.5) / max(coneWidth * 0.62, 0.02), 2.0) * 1.35);
            const float brokenLight = mix(0.82, 1.0, noise);
            const float smoothness = max(descriptor.values.z, 0.05);
            const float rays = mix(0.72, 1.0, smoothstep(0.0, smoothness, softBeam));
            const float falloff = pow(1.0 - depth, 0.65) * cone;
            const float intensity = saturate(softBeam * rays * falloff * (descriptor.extra.y * kAuthoredMagnitudeScale) * mask);
            const float3 lightColor = mix(float3(1.0, 0.78, 0.52), descriptor.extra2.xyz, 0.35);
            color.rgb += lightColor * intensity * brokenLight;
            color.a = max(color.a, intensity);
        } else if (descriptor.kind == 50) {
            if (descriptor.values.x <= 0.0001) { continue; }
            const float2 scene = input.sceneCoordinate;
            const float diagonal = scene.x * 0.62 + (1.0 - scene.y) * 0.38;
            const float phase = effect.time * descriptor.values.y;
            const float beamA = exp(-pow((diagonal - 0.22 - sin(phase * 0.21) * 0.05) / max(descriptor.values.z, 0.03), 2.0));
            const float beamB = exp(-pow((diagonal - 0.52 - cos(phase * 0.17) * 0.04) / max(descriptor.values.z * 1.45, 0.04), 2.0));
            const float beamC = exp(-pow((diagonal - 0.82 - sin(phase * 0.13) * 0.03) / max(descriptor.values.z * 1.9, 0.05), 2.0));
            const float noise = fogNoise(scene * max(descriptor.extra.x, 0.1) * 3.0 + effect.time * descriptor.values.y * 0.12);
            const float falloff = pow(saturate(1.0 - scene.y), 0.75);
            const float shaft = saturate((beamA * 0.8 + beamB * 0.55 + beamC * 0.35) * falloff * (0.78 + noise * descriptor.values.w));
            const float3 lightColor = mix(float3(1.0, 0.78, 0.52), descriptor.extra2.xyz, 0.35);
            const float authoredColorwIntensity = descriptor.values.x * kAuthoredMagnitudeScale;
            color.rgb += lightColor * shaft * authoredColorwIntensity * 0.55 * mask;
            color.a = max(color.a, shaft * authoredColorwIntensity * 0.2 * mask);
        } else if (descriptor.kind == 12) {
            color.rgb = mix(color.rgb, descriptor.values.rgb, descriptor.values.w * mask);
        } else if (descriptor.kind == 13) {
            color.a *= mix(1.0, descriptor.values.x, mask);
        } else if (descriptor.kind == 16) {
            const float2 center = descriptor.extra.xy;
            const float2 delta = coordinate - center;
            const float falloff = mix(0.5 / (length(delta) + 0.0001), 1.0, descriptor.values.z);
            const float2 direction = float2(-sin(descriptor.values.x), cos(descriptor.values.x))
                * (descriptor.values.y * kAuthoredMagnitudeScale) * 0.01 * falloff;
            const float2 sample0 = coordinate + direction;
            const float2 sample1 = coordinate - direction;
            const float4 base = color;
            color.r = texture.sample(linearSampler, sample0).r;
            color.b = texture.sample(linearSampler, sample1).b;
            color = mix(base, color, mask);
        } else if (descriptor.kind == 17) {
            const float2 center = descriptor.values.zw;
            const float2 delta = maskCoordinate - center;
            const float spinMask = smoothstep(descriptor.values.x + descriptor.values.y + 0.00001,
                                              descriptor.values.x - descriptor.values.y,
                                              length(delta));
            const float angle = effect.time * 0.6 * spinMask * mask;
            const float s = sin(angle);
            const float c = cos(angle);
            const float2 rotated = center + float2(delta.x * c - delta.y * s, delta.x * s + delta.y * c);
            const float4 base = color;
            color = mix(base, texture.sample(linearSampler, rotated), spinMask * mask);
        } else if (descriptor.kind == 18) {
            const float delta = dot(abs(descriptor.extra.xyz - color.rgb), float3(1.0));
            const float blend = smoothstep(0.001, 0.002 + descriptor.values.y,
                                           delta - descriptor.values.z);
            color.a *= mix(descriptor.values.x, 1.0, blend) * mask + (1.0 - mask);
        } else if (descriptor.kind == 19) {
            // extra.x is the bound slot of the blend image, extra.y its BLENDMODE.
            if (descriptor.extra.x >= 0.0) {
                const float4 blendColor = effectSlotColor(uint(descriptor.extra.x), maskCoordinate,
                                                          mask0, mask1, mask2, mask3, linearSampler);
                const float amount = saturate(descriptor.values.x * mask) * blendColor.a;
                color.rgb = applyBlending(int(descriptor.extra.y), color.rgb, blendColor.rgb, amount);
            }
        } else if (descriptor.kind == 20) {
            const float gradient = saturate(input.sceneCoordinate.y);
            color.rgb = mix(color.rgb, float3(gradient, 1.0 - gradient, 1.0), descriptor.values.x * mask * 0.35);
        } else if (descriptor.kind == 21) {
            const float2 center = float2(0.5);
            const float2 radial = normalize(coordinate - center + 0.0001);
            const float amount = descriptor.values.x * 0.01;
            color = (color + texture.sample(linearSampler, coordinate + radial * amount)
                + texture.sample(linearSampler, coordinate - radial * amount)) / 3.0;
        } else if (descriptor.kind == 22) {
            const float waves = 0.5 + 0.5 * sin(coordinate.x * 35.0 + coordinate.y * 28.0 + effect.time * descriptor.values.y);
            color.rgb += waves * descriptor.values.x * mask;
        } else if (descriptor.kind == 25) {
            const float l = dot(texture.sample(linearSampler, coordinate - float2(0.002, 0)).rgb, float3(0.299, 0.587, 0.114));
            const float r = dot(texture.sample(linearSampler, coordinate + float2(0.002, 0)).rgb, float3(0.299, 0.587, 0.114));
            const float edge = abs(r - l) * descriptor.values.x * mask;
            color.rgb = mix(color.rgb, float3(edge), saturate(edge));
        } else if (descriptor.kind == 26) {
            const float grain = fogNoise(coordinate * 180.0 + effect.time * descriptor.values.y * 20.0) - 0.5;
            color.rgb += grain * descriptor.values.x * mask;
        } else if (descriptor.kind == 27) {
            const float heat = fogNoise(coordinate * 8.0 + float2(0, effect.time * descriptor.values.y));
            color.rgb = mix(color.rgb, color.rgb + float3(1.0, 0.18, 0.02) * heat, descriptor.values.x * mask);
        } else if (descriptor.kind == 29) {
            const float2 reflectedCoordinate = float2(coordinate.x, 1.0 - coordinate.y);
            color = mix(color, texture.sample(linearSampler, reflectedCoordinate), descriptor.values.x * mask);
        } else if (descriptor.kind == 32) {
            color.rgb *= 1.0 + descriptor.values.x * mask;
        } else if (descriptor.kind == 35) {
            // X-Ray is a cursor-bound reveal. Keep the authored image unchanged
            // outside the reveal and use neutral luminance inside it; this avoids
            // the old hard-coded green cast and follows the mouse position.
            const float2 pointer = float2(effect.cursor.x + 0.5,
                                         0.5 - effect.cursor.y);
            const float aspect = layer.size.x / max(layer.size.y, 1.0);
            const float2 delta = (coordinate - pointer) * float2(aspect, 1.0);
            const float radius = max(0.04, 0.5 * max(descriptor.values.x, 0.0));
            const float reveal = 1.0 - smoothstep(radius - 0.012, radius + 0.012, length(delta));
            const float4 alternate = xrayTexture.sample(linearSampler, coordinate);
            const float4 revealColor = alternate;
            const float revealAmount = reveal * mask;
            color.rgb = mix(color.rgb, revealColor.rgb, revealAmount);
            color.a = mix(color.a, revealColor.a, revealAmount);
        } else if (descriptor.kind == 36 || descriptor.kind == 37) {
            const float blur = descriptor.values.x * 0.01;
            color = mix(color, gaussianBlur5(texture, linearSampler, coordinate, blur), mask);
        } else if (descriptor.kind == 39) {
            const float sparkle = pow(saturate(fogNoise(coordinate * 80.0 + effect.time * descriptor.values.y * 8.0)), 12.0);
            color.rgb += sparkle * descriptor.values.x * mask;
        } else if (descriptor.kind == 40) {
            const float3 neighborhood = (texture.sample(linearSampler, coordinate + float2(0.004, 0)).rgb
                + texture.sample(linearSampler, coordinate - float2(0.004, 0)).rgb
                + texture.sample(linearSampler, coordinate + float2(0, 0.004)).rgb
                + texture.sample(linearSampler, coordinate - float2(0, 0.004)).rgb) / 4.0;
            color.rgb += (color.rgb - neighborhood) * descriptor.values.x * mask;
        } else if (descriptor.kind == 41) {
            const float blur = descriptor.values.x * 0.012;
            color = mix(color, gaussianBlurPrecise(texture, linearSampler, coordinate, blur), mask);
        } else if (descriptor.kind == 43) {
            const float sweep = smoothstep(0.0, 0.18, sin((coordinate.x + coordinate.y) * 3.14159265
                + effect.time * descriptor.values.y) * 0.5 + 0.5);
            color.rgb += float3(1.0, 0.95, 0.8) * sweep * descriptor.values.x * mask;
        } else if (descriptor.kind == 44) {
            color = color;
        } else if (descriptor.kind == 45) {
            const float shimmer = smoothstep(0.72, 1.0,
                0.5 + 0.5 * sin((coordinate.x + coordinate.y) * 18.0 + effect.time * descriptor.values.y));
            color.rgb += float3(1.0, 0.9, 0.7) * shimmer * descriptor.values.x * mask;
        } else if (descriptor.kind == 48) {
            const float response = audioRangeResponse(effect, descriptor.values.z, descriptor.values.w,
                                                      descriptor.extra.xy, descriptor.values.y, descriptor.values.x);
            const float angle = response * (descriptor.extra.z * kAuthoredMagnitudeScale) * 6.2831853;
            color.rgb = mix(color.rgb, hueRotate(color.rgb, angle), mask);
            color.rgb += response * mask * float3(0.12, 0.24, 0.45);
        } else if (descriptor.kind == 47) {
            const int barCount = int(clamp(round(descriptor.values.z), 4.0, 16.0));
            const float scaledX = clamp(coordinate.x, 0.0, 0.9999) * float(barCount);
            const int barIndex = int(floor(scaledX));
            const float inBar = fract(scaledX);
            const float gap = clamp(descriptor.extra2.x, 0.0, 0.75) * 0.5;
            const float feather = min(0.025, max(0.006, (0.5 - gap) * 0.18));
            const float edge = smoothstep(gap, gap + feather, inBar) * (1.0 - smoothstep(1.0 - gap - feather, 1.0 - gap, inBar));
            const float band = audioBandValue(effect, min(barIndex, 15));
            const float height = clamp(descriptor.values.w + pow(max(band, 0.0), 0.55) * (descriptor.values.y * kAuthoredMagnitudeScale), 0.0, 1.0);
            const float localYFromBottom = 1.0 - coordinate.y;
            const float fill = smoothstep(height + 0.035, height - 0.015, localYFromBottom) * edge * mask;
            const float glow = exp(-abs(localYFromBottom - height) * 18.0) * edge * descriptor.extra.w * mask;
            const float3 barColor = descriptor.extra.rgb * (0.75 + band * 0.65);
            const float alpha = saturate((fill + glow * 0.65) * descriptor.values.x);
            color.rgb = mix(color.rgb, barColor, alpha);
            color.a = max(color.a, alpha);
        } else if (descriptor.kind == 49) {
            const float response = audioRangeResponse(effect, descriptor.values.z, descriptor.values.w,
                                                      descriptor.extra.xy, descriptor.values.y, descriptor.values.x);
            const float2 centered = maskCoordinate - 0.5;
            const float radial = saturate(length(centered) * 2.0);
            const float streaks = pow(0.5 + 0.5 * sin(atan2(centered.y, centered.x) * 18.0 + radial * 28.0 - effect.time * (4.0 + descriptor.extra.w * 6.0)), 8.0);
            const float glow = response * streaks * radial * mask * (descriptor.extra.z * kAuthoredMagnitudeScale);
            color.rgb += glow * float3(0.35, 0.65, 1.0);
            color.a = max(color.a, max(glow * 0.8, response * radial * mask * 0.18));
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
    const float blur = max(layer.blur, 0.0) * 0.004;
    if (blur > 0.0) {
        color = gaussianBlur5(texture, linearSampler, coordinate, blur);
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
    if (layer.effects.w > 0.0001) {
        // Blur the bright-pass over a small neighborhood so bloom actually glows/spreads instead of just self-brightening.
        const float2 bloomStep = float2(0.0035, 0.0035);
        float3 brightAccum = float3(0.0);
        for (int dx = -1; dx <= 1; ++dx) {
            for (int dy = -1; dy <= 1; ++dy) {
                const float2 sampleCoordinate = coordinate + float2(float(dx), float(dy)) * bloomStep;
                const float3 sampleColor = texture.sample(linearSampler, sampleCoordinate).rgb;
                brightAccum += max(sampleColor - layer.colorEffects.w, 0.0);
            }
        }
        brightAccum /= 9.0;
        color.rgb += brightAccum * layer.effects.w * layer.bloomTint.rgb;
    }
    return color * layer.opacity * layer.color;
}