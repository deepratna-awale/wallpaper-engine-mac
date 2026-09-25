import Cocoa
import MetalKit
import CryptoKit

struct LayerUniform {
    var position: SIMD2<Float>
    var size: SIMD2<Float>
    var sceneSize: SIMD2<Float>
    var opacity: Float
    var particleShape: Float
    var rotation: Float
    var color: SIMD4<Float>
    var uvOrigin: SIMD2<Float>
    var uvAxisX: SIMD2<Float>
    var uvAxisY: SIMD2<Float>
    var effects: SIMD4<Float>
    var blur: Float
    var colorEffects: SIMD4<Float>
    var transform: SIMD4<Float>
    var transformScaleY: Float
    var bloomTint: SIMD4<Float> = SIMD4<Float>(repeating: 1)
}

struct DXTDecodeUniform {
    var width: UInt32
    var height: UInt32
    var blockColumns: UInt32
    var format: UInt32
}

struct EffectUniform {
    var time: Float
    var pulse: Float
    var cursor: SIMD2<Float> = .zero
    var audioBands0: SIMD4<Float> = .zero
    var audioBands1: SIMD4<Float> = .zero
    var audioBands2: SIMD4<Float> = .zero
    var audioBands3: SIMD4<Float> = .zero
}

struct EffectDescriptorGPU {
    var kind: UInt32
    var maskIndex: UInt32
    var values: SIMD4<Float>
    var extra: SIMD4<Float>
    var extra2: SIMD4<Float> = .zero
    var extra3: SIMD4<Float> = .zero
}
