//
//  SceneParticleEmitterSpace.swift
//  Open Wallpaper Engine
//

import simd

/// Maps a particle system's emitter-local geometry into scene space with the emitter object's
/// world transform (its own and its parents' origin, scale and angle).
struct SceneParticleEmitterSpace {
    let world: SceneAffineTransform

    /// Where the emitter sits in scene space.
    var origin: SIMD2<Float> { world.translation }

    /// A spawn box's half extent (`distancemax`), scaled by the world scale on each axis.
    func extent(_ distance: SIMD2<Float>) -> SIMD2<Float> {
        simd_abs(distance * world.axisScale)
    }

    /// An emitter-local offset given y-down (as the particle builder stores control points and
    /// position offsets), scaled and rotated into scene space and returned y-down.
    func offset(_ yDown: SIMD2<Float>) -> SIMD2<Float> {
        let flip = SIMD2<Float>(1, -1)
        return (world.linear * (yDown * flip)) * flip
    }
}
