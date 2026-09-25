import simd

/// A child's control points taken from its parent's particles (link flag 1, WE's "set control
/// points to particle positions"): from `controlpointstartindex` on, control point `start + i` is
/// the parent's particle `i` (spawn order), each frame. WE's docs: "Control point 0 is always tied
/// to the origin position of the particle system", so control point 0 keeps it. A static child of an
/// instanced system reads its own parent instance's particles; any other child, all of its
/// parent's. `ParticleSimulation.metal`'s `linkPoints` does the same on the GPU.
enum ParticleControlPointLink {
    /// The frame points (`ParticleFrameInputs.LinkedPoint`) in order, with the control point each
    /// sits on; −1 for none.
    static func controlPoints(of configuration: SceneMetalParticleSystem) -> [Int] {
        var ids = [Int](repeating: -1, count: LinkedPoint.allCases.count)
        ids[LinkedPoint.spawnOrigin.rawValue] = configuration.emitterControlPoint ?? -1
        ids[LinkedPoint.attractor.rawValue] = configuration.attractor?.controlPoint ?? -1
        ids[LinkedPoint.sequenceStart.rawValue] = configuration.sequenceSpan?.startControlPoint ?? -1
        ids[LinkedPoint.sequenceEnd.rawValue] = configuration.sequenceSpan?.endControlPoint ?? -1
        ids[LinkedPoint.remapAnchor.rawValue] = configuration.initialRemap?.controlPoint ?? -1
        ids[LinkedPoint.vortex.rawValue] = configuration.vortex?.controlPoint ?? -1
        ids[LinkedPoint.reduction.rawValue] = configuration.nearControlPointReduction?.controlPoint ?? -1
        ids[LinkedPoint.constraint.rawValue] = configuration.maintainControlPointDistance?.controlPoint ?? -1
        return ids
    }

    /// The frame points that sit on a control point, in `ParticleGPUParameters.pointControlPoints`
    /// order.
    enum LinkedPoint: Int, CaseIterable {
        case spawnOrigin, attractor, sequenceStart, sequenceEnd, remapAnchor, vortex, reduction, constraint
    }

    /// The parent particles' positions `system`'s control points take this step (instance `slot` of
    /// an instanced system), oldest first; empty without the link.
    static func positions(for system: ParticleSystemRuntime, slot: Int) -> [SIMD2<Float>] {
        guard let link = system.configuration.link, let start = link.controlPointStart,
              let parent = system.parent else { return [] }
        let wanted = max(8 - start, 0)
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
    /// These inputs with the points on control points `start…` moved to `positions` (plus the
    /// operators' own offsets). The positions are in the scene, so the points stay put in every
    /// instance.
    func linked(_ positions: [SIMD2<Float>], start: Int, controlPoints: [Int]) -> ParticleFrameInputs {
        var inputs = self
        for point in ParticleControlPointLink.LinkedPoint.allCases {
            let id = controlPoints[point.rawValue]
            let index = id - start
            guard id >= max(start, 1), index < positions.count else { continue }
            let position = positions[index]
            switch point {
            case .spawnOrigin: inputs.spawnOrigin = position
            case .attractor: inputs.attractorOrigin = position + attractorOffset
            case .sequenceStart: inputs.sequenceStart = inputs.sequenceStart.map { _ in position }
            case .sequenceEnd: inputs.sequenceEnd = inputs.sequenceEnd.map { _ in position }
            case .remapAnchor: inputs.remapAnchor = position
            case .vortex: inputs.vortexOrigin = position
            case .reduction: inputs.reductionOrigin = position + reductionOffset
            case .constraint: inputs.constraintOrigin = position + constraintOffset
            }
        }
        return inputs
    }
}
