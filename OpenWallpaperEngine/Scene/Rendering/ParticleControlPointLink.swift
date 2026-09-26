import simd

/// A child's control points taken from its parent's particles (link flag 1, WE's "set control
/// points to particle positions"): from `controlpointstartindex` on, control point `start + i` is
/// the parent's particle `i` (spawn order), each frame. WE's docs: "Control point 0 is always tied
/// to the origin position of the particle system", so control point 0 keeps it. A static child of an
/// instanced system reads its own parent instance's particles; any other child, all of its
/// parent's. `ParticleSimulation.metal`'s `linkPoints` does the same on the GPU.
enum ParticleControlPointLink {
    /// The parent particles' positions `system`'s control points take this step (instance `slot` of
    /// an instanced system), oldest first; empty without the link.
    static func positions(for system: ParticleSystemRuntime, slot: Int) -> [SIMD2<Float>] {
        guard let link = system.configuration.link, let start = link.controlPointStart,
              let parent = system.parent else { return [] }
        let wanted = max(ParticleControlPoint.count - start, 0)
        let perInstance = link.kind == .static && link.instanced
        var positions: [SIMD2<Float>] = []
        for particle in parent.particles where positions.count < wanted {
            if perInstance, particle.instance != slot { continue }
            positions.append(particle.position)
        }
        return positions
    }
}

extension ParticleFrameInputs {
    /// These inputs with control points `start…` on the scene `positions`: they stay put in every
    /// instance.
    func linked(_ positions: [SIMD2<Float>], start: Int) -> ParticleFrameInputs {
        var inputs = self
        let toSpace = self.toSpace
        for (offset, position) in positions.enumerated() {
            let index = start + offset
            guard index >= max(start, 1), index < ParticleControlPoint.count else { continue }
            inputs.controlPoints[index] = toSpace * (position - space.translation)
            inputs.absolutePoints |= 1 << UInt32(index)
        }
        return inputs
    }
}
