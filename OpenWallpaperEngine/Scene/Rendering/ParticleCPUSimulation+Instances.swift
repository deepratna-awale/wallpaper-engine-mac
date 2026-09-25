import simd

/// Instanced child systems on the CPU (`ParticleChildLink`). `ParticleInstances.metal` runs the same
/// steps on the GPU; the order of every loop is part of the contract, since instances are handed
/// out in slot order to events in their parent's particle order.
extension ParticleCPUSimulation {
    /// One step of `system`'s instances before its particles spawn: follow sources, retire
    /// finished instances, start instances for the parent's events and decide each instance's
    /// emission (`spawnCount`).
    static func updateInstances(_ system: ParticleSystemRuntime, inputs: ParticleFrameInputs) {
        guard let link = system.configuration.link, let parent = system.parent else { return }
        let configuration = system.configuration
        for index in system.instances.indices {
            var instance = system.instances[index]
            instance.previousTranslation = instance.translation
            instance.spawnCount = 0
            if link.kind == .static {
                // One instance per parent instance, where that instance is.
                let source = index < parent.instances.count ? parent.instances[index] : ParticleInstance()
                if source.fresh {
                    let live = instance.live
                    instance = ParticleInstance(active: true, emitting: true, fresh: true)
                    instance.live = live
                    instance.translation = source.translation
                    instance.previousTranslation = source.translation
                    instance.inheritSource(of: source)
                } else if instance.active {
                    instance.fresh = false
                    instance.translation = source.translation
                    instance.inheritSource(of: source)
                    // It runs for as long as its parent instance does.
                    instance.emitting = source.active
                }
            } else if instance.active {
                instance.fresh = false
                instance.clearing = false
                switch link.kind {
                case .follow, .spawn:
                    if instance.emitting {
                        if let source = particle(serial: instance.sourceSerial, in: parent.particles) {
                            instance.track(source)
                        } else {
                            instance.emitting = false
                            instance.clearing = link.kind == .follow
                        }
                    }
                case .death, .static:
                    // A death instance emits for the step it was made in.
                    instance.emitting = false
                }
            }
            if instance.active, !instance.emitting, !instance.clearing, !instance.fresh, instance.live == 0 {
                instance = ParticleInstance()
            }
            system.instances[index] = instance
        }
        if link.kind != .static {
            let events = link.kind == .death ? parent.diedThisStep : parent.spawnedThisStep
            var slot = 0
            for event in events {
                guard ParticleRandom.unit(seed: system.seed, serial: event.serial,
                                          stream: ParticleRandom.Stream.eventProbability.rawValue) < link.probability else { continue }
                while slot < system.instances.count, system.instances[slot].active { slot += 1 }
                guard slot < system.instances.count else { break }
                var instance = ParticleInstance(active: true, emitting: true, fresh: true)
                instance.sourceSerial = event.serial
                instance.track(event)
                instance.previousTranslation = instance.translation
                system.instances[slot] = instance
            }
        }
        for index in system.instances.indices where system.instances[index].active && system.instances[index].emitting {
            var instance = system.instances[index]
            let step = instance.clock.advance(inputs.deltaTime, timing: configuration.emitterTiming, seed: system.seed,
                                              key: clockKey(instance, slot: index))
            let limit = ParticleEmitterClock.rateLimit(periodLimit: inputs.periodLimit, emitted: Int(instance.clock.state.w),
                                                       onePerFrame: inputs.onePerFrame)
            let emitted = emission(liveCount: instance.live, maximum: inputs.maximum,
                                   rate: step.emits ? inputs.emissionRate : 0, deltaTime: inputs.deltaTime,
                                   remainder: &instance.remainder,
                                   burst: step.bursts ? configuration.instantaneous : 0, rateLimit: limit)
            instance.clock.state.w += Float(emitted.rate)
            instance.spawnCount = emitted.burst + emitted.rate
            system.instances[index] = instance
        }
    }

    /// Names an instance's random periods: its event (the parent particle's serial) and its slot.
    static func clockKey(_ instance: ParticleInstance, slot: Int) -> UInt32 {
        instance.sourceSerial &* 31 &+ UInt32(slot) &+ 1
    }

    /// The live particle with `serial`: particles stay in spawn order, so serials increase.
    static func particle(serial: UInt32, in particles: [Particle]) -> Particle? {
        guard let first = particles.first else { return nil }
        var low = 0, high = particles.count
        while low < high {
            let middle = (low + high) / 2
            if particles[middle].serial &- first.serial < serial &- first.serial { low = middle + 1 } else { high = middle }
        }
        return low < particles.count && particles[low].serial == serial ? particles[low] : nil
    }

    /// Carries a particle of a local-space instanced system along with its instance.
    static func followInstance(_ particle: inout Particle, instance: ParticleInstance, inputs: ParticleFrameInputs) {
        guard inputs.motion != nil || instance.translation != instance.previousTranslation else { return }
        let motion = inputs.motion ?? .identity
        let carried = SceneAffineTransform(linear: motion.linear,
                                           translation: instance.translation + motion.translation
                                               - motion.linear * instance.previousTranslation)
        follow(&particle, motion: carried)
    }

    /// Each instance's particles after the step.
    static func countInstanceParticles(_ system: ParticleSystemRuntime) {
        for index in system.instances.indices { system.instances[index].live = 0 }
        for particle in system.particles where particle.instance < system.instances.count {
            system.instances[particle.instance].live += 1
        }
    }
}
