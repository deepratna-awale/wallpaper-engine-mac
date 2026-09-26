import simd

/// `remapvalue` and `remapinitialvalue` records that write a control point (the `controlpoint`
/// output; the initializer's control point inputs, which zero it) write into the system's shared
/// control point array, as WE's do (`wallpaper64.exe` 0x140246781, 0x14023eac2, 0x14023d31d): later
/// spawns, particles and records of the step read what they wrote.
///
/// WE's operator VM runs record by record over every particle, four at a time (0x14023fbc0): each
/// group of four reads the control point as the previous group left it, and the `controlpoint`
/// output keeps the value of the group's first particle. A program with such a record runs here in
/// that order (`advanceOperatorMajor`), groups counted by particle order within each instance. After
/// the step the written points are the previous points of the next step (WE copies them after the
/// VM, 0x140237798), and a point the object's instance override drives keeps its written value
/// until the override changes (WE's update skips those points, 0x14022e468).
extension ParticleCPUSimulation {
    /// Every operator, record by record over every particle.
    static func advanceOperatorMajor(_ system: ParticleSystemRuntime, inputs: inout ParticleFrameInputs,
                                     instanceInputs: inout [ParticleFrameInputs], neighbors: ParticleProgramCPU.Neighbors) {
        let instanced = !instanceInputs.isEmpty
        func own(_ particle: Particle) -> ParticleFrameInputs { instanced ? instanceInputs[particle.instance] : inputs }
        var states = system.particles.map { programState($0, inputs: own($0)) }
        var contexts = system.particles.map { particle in
            var context = context(system, inputs: own(particle), serial: particle.serial,
                                  source: instanced ? system.instances[particle.instance] : nil)
            context.deltaTime /= Float(inputs.substeps)
            context.dragDeltaTime /= Float(inputs.substeps)
            return context
        }
        var dies = [Bool](repeating: false, count: states.count)
        var points = instanced ? instanceInputs.map(\.controlPoints) : [inputs.controlPoints]
        for _ in 0..<inputs.substeps {
            for index in states.indices { ParticleProgramCPU.beginRun(&states[index]) }
            for record in inputs.operators {
                var lanes = [Int](repeating: 0, count: points.count)
                var groupStart = points
                for index in states.indices {
                    let slot = instanced ? system.particles[index].instance : 0
                    let first = lanes[slot] % 4 == 0
                    if first { groupStart[slot] = points[slot] }
                    contexts[index].controlPoints = groupStart[slot]
                    if ParticleProgramCPU.runOperator(record, on: &states[index], in: &contexts[index], index: index,
                                                      neighbors: neighbors) {
                        dies[index] = true
                    }
                    if first { points[slot] = contexts[index].controlPoints }
                    lanes[slot] += 1
                }
            }
        }
        for index in system.particles.indices {
            finish(&system.particles[index], state: states[index], dies: dies[index], system: system,
                   inputs: own(system.particles[index]))
        }
        if instanced {
            for slot in instanceInputs.indices { instanceInputs[slot].controlPoints = points[slot] }
        } else {
            inputs.controlPoints = points[0]
        }
    }

    /// Keeps a system's written control points for its next step: as the previous points, in the
    /// scene for its children, and on the points its instance override drives.
    static func keepWrittenControlPoints(_ system: ParticleSystemRuntime, inputs: ParticleFrameInputs) {
        system.previousControlPoints = inputs.controlPoints
        for index in 0..<ParticleControlPoint.count {
            system.lastControlPoints[index] = inputs.space.apply(inputs.controlPoints[index])
            if let driven = inputs.overridePoints[index] {
                system.writtenOverridePoints[index] = (override: driven, point: inputs.controlPoints[index])
            }
        }
    }
}
