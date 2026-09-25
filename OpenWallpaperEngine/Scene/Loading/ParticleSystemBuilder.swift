import simd

/// Builds a particle system's simulation configuration (`SceneMetalParticleSystem`) from its json:
/// the emitter, initializers, operators and renderer. The view model loads the assets it draws with.
enum ParticleSystemBuilder {
    static func build(_ particlePath: String, particleSystem: WEParticleSystem, object: WESceneObject,
                      world: SceneAffineTransform, overrides: SceneParticleOverrides, sceneSize: SIMD2<Float>,
                      source: SceneMetalTextureSource, spriteSheet: SpriteSheet?, material: WEMaterial,
                      materialPlan: ParticleMaterialPlan?) -> SceneMetalParticleSystem {
        let particleRenderer = particleSystem.renderer?.first
        let emitter = particleSystem.emitter?.first
        let emitterSpace = SceneParticleEmitterSpace(world: world)
        let origin = emitterSpace.origin
        // Instance overrides scale these authored values every frame (`ParticleFrameInputs`).
        let rate = Float(emitter?.rate ?? 100)
        let rateScript = overrides.rateScript ?? emitter?.$rate.script
        let distance = emitter?.distancemax?.vectorValue ?? (0, 0, 0)
        let directions = emitter?.directions?.vectorValue ?? (1, 1, 0)
        let spawnExtent = SIMD2<Float>(Float(distance.0 * directions.0), Float(distance.1 * directions.1))
        var lifetime: ClosedRange<Float> = 1...1
        var size: ClosedRange<Float> = 20...20
        var minimumVelocity = SIMD2<Float>.zero
        var maximumVelocity = SIMD2<Float>.zero
        var alpha: ClosedRange<Float> = 1...1
        var minimumColor = SIMD4<Float>(repeating: 1)
        var maximumColor = SIMD4<Float>(repeating: 1)
        var minimumRotation: Float = 0
        var maximumRotation: Float = 0
        var minimumAngularVelocity: Float = 0
        var maximumAngularVelocity: Float = 0
        var positionOffsetMinimum = SIMD2<Float>.zero
        var positionOffsetMaximum = SIMD2<Float>.zero
        var remapAlpha: ParticleRemap?
        var nearControlPointReduction: ParticleDistanceReduction?
        var maintainControlPointDistance: ParticleDistanceConstraint?
        var sequenceSpan: ParticleSequenceSpan?
        var sequenceRing: ParticleSequenceRing?
        var initialRemap: ParticleInitialRemap?
        var maintainSequenceDistance = false
        var collisions: [ParticleCollision] = []
        var velocityAudio: ParticleAudioResponse?
        var audioVelocityMinimum = SIMD2<Float>.zero, audioVelocityMaximum = SIMD2<Float>.zero
        var turbulenceAudio: ParticleAudioResponse?
        var vortexAudio: ParticleAudioResponse?
        var inheritOnSpawn: ParticleInheritance = []
        var inheritEachStep: ParticleInheritance = []
        /// An `inherit…fromevent` element's verb (`default` when it names none); nil logs it.
        func inheritance(_ input: String?, default fallback: ParticleInheritance, element: String) -> ParticleInheritance {
            guard let input, !input.isEmpty else { return fallback }
            guard let verbs = ParticleInheritance(input: input) else {
                OWELog.error(.scene, "Particle system \(particlePath): \(element) has an unknown input \(input); ignored")
                return []
            }
            return verbs
        }
        var controlPoints: [ParticleControlPoint] = (particleSystem.controlpoint ?? []).map { controlPoint in
            let offset = (controlPoint.offset ?? "0 0 0").parseVector3()
            return ParticleControlPoint(id: controlPoint.id ?? 0,
                                        offset: SIMD2<Float>(Float(offset.0), -Float(offset.1)),
                                        locksToCursor: controlPoint.locktopointer == true
                                            || ((controlPoint.flags ?? 0) & 1) != 0)
        }
        // The object's `controlpoint<n>` overrides place them.
        for (id, position) in overrides.controlPoints.sorted(by: { $0.key < $1.key }) {
            let offset = SIMD2<Float>(position.x, -position.y)
            if let index = controlPoints.firstIndex(where: { $0.id == id }) {
                controlPoints[index] = ParticleControlPoint(id: id, offset: offset, locksToCursor: controlPoints[index].locksToCursor)
            } else {
                controlPoints.append(ParticleControlPoint(id: id, offset: offset, locksToCursor: false))
            }
        }
        for initializer in particleSystem.initializer ?? [] {
            switch initializer.name {
            case "lifetimerandom":
                let lifetimeMin = Float(initializer.min?.doubleValue ?? 1)
                let lifetimeMax = Float(initializer.max?.doubleValue ?? 1)
                lifetime = min(lifetimeMin, lifetimeMax)...max(lifetimeMin, lifetimeMax)
            case "sizerandom":
                let sizeMin = Float(initializer.min?.doubleValue ?? 20)
                let sizeMax = Float(initializer.max?.doubleValue ?? 20)
                size = min(sizeMin, sizeMax)...max(sizeMin, sizeMax)
            case "velocityrandom":
                let minimum = initializer.min?.vectorValue ?? (0, 0, 0)
                let maximum = initializer.max?.vectorValue ?? (0, 0, 0)
                minimumVelocity = SIMD2<Float>(Float(minimum.0), Float(minimum.1))
                maximumVelocity = SIMD2<Float>(Float(maximum.0), Float(maximum.1))
            case "turbulentvelocityrandom":
                let minimum = initializer.min?.vectorValue ?? (0, 0, 0)
                let maximum = initializer.max?.vectorValue ?? (0, 0, 0)
                let low = SIMD2<Float>(Float(minimum.0), Float(minimum.1)), high = SIMD2<Float>(Float(maximum.0), Float(maximum.1))
                if let response = ParticleAudioResponse(initializer) {
                    velocityAudio = response
                    audioVelocityMinimum += low
                    audioVelocityMaximum += high
                } else {
                    minimumVelocity += low
                    maximumVelocity += high
                }
            case "positionoffsetrandom":
                let minimum = initializer.min?.vectorValue ?? (0, 0, 0)
                let maximum = initializer.max?.vectorValue ?? (0, 0, 0)
                positionOffsetMinimum = SIMD2<Float>(Float(minimum.0), -Float(minimum.1))
                positionOffsetMaximum = SIMD2<Float>(Float(maximum.0), -Float(maximum.1))
            case "hsvcolorrandom":
                minimumColor = normalizedParticleColor(initializer.min?.vectorValue ?? (1, 1, 1))
                maximumColor = normalizedParticleColor(initializer.max?.vectorValue ?? (1, 1, 1))
            case "alpharandom":
                let alphaMin = Float(initializer.min?.doubleValue ?? 1)
                let alphaMax = Float(initializer.max?.doubleValue ?? 1)
                alpha = min(alphaMin, alphaMax)...max(alphaMin, alphaMax)
            case "colorrandom":
                minimumColor = normalizedParticleColor(initializer.min?.vectorValue ?? (1, 1, 1))
                maximumColor = normalizedParticleColor(initializer.max?.vectorValue ?? (1, 1, 1))
            case "rotationrandom":
                minimumRotation = Float(initializer.min?.vectorValue.2 ?? 0)
                maximumRotation = Float(initializer.max?.vectorValue.2 ?? 0)
            case "angularvelocityrandom":
                minimumAngularVelocity = Float(initializer.min?.vectorValue.2 ?? 0)
                maximumAngularVelocity = Float(initializer.max?.vectorValue.2 ?? 0)
            case "mapsequencebetweencontrolpoints":
                sequenceSpan = ParticleSequenceSpan(startControlPoint: initializer.controlpoint0 ?? 0,
                                                    endControlPoint: initializer.controlpoint1 ?? 1,
                                                    count: max(2, Int(initializer.count ?? 2)),
                                                    arcAmount: Float(initializer.arcamount ?? 0),
                                                    mirrored: initializer.limitbehavior?.lowercased() == "mirror")
            case "mapsequencearoundcontrolpoint":
                let axis = (initializer.axis ?? "0 1 0").parseVector3()
                let bounds = (initializer.bounds ?? "0 1").split(separator: " ").compactMap { Float($0) }
                let speedMinimum = initializer.speedmin?.vectorValue ?? (0, 0, 0)
                let speedMaximum = initializer.speedmax?.vectorValue ?? (0, 0, 0)
                sequenceRing = ParticleSequenceRing(turns: Float(initializer.count ?? 1),
                                                    axis: SIMD2<Float>(Float(axis.0), -Float(axis.1)),
                                                    bounds: (bounds.first ?? 0)...max(bounds.first ?? 0, bounds.count > 1 ? bounds[1] : 1),
                                                    minimumSpeed: SIMD2<Float>(Float(speedMinimum.0), -Float(speedMinimum.1)),
                                                    maximumSpeed: SIMD2<Float>(Float(speedMaximum.0), -Float(speedMaximum.1)))
            case "inheritinitialvaluefromevent":
                inheritOnSpawn.formUnion(inheritance(initializer.input, default: .setColor, element: "inheritinitialvaluefromevent"))
            case "remapinitialvalue":
                // Presets leave `output` implicit; size is the property that visibly tapers a strand
                // towards its anchor, and velocity damping is already covered by other operators.
                let output: ParticleInitialRemap.Output
                switch initializer.output?.lowercased() {
                case "alpha": output = .alpha
                case "velocity": output = .velocity
                default: output = .size
                }
                initialRemap = ParticleInitialRemap(controlPoint: initializer.inputcontrolpoint0 ?? 0,
                                                    rangeMinimum: Float(initializer.inputrangemin ?? 0),
                                                    rangeMaximum: Float(initializer.inputrangemax ?? 1),
                                                    multiply: initializer.operation?.lowercased() != "set",
                                                    output: output)
            default: break
            }
        }
        var gravity = SIMD2<Float>.zero
        var worldGravity = false
        var drag: Float = 0
        var fadeIn: Float = 0
        var fadeOut: Float = 1
        var dragScript: String?
        var fadeInScript: String?
        var fadeOutScript: String?
        var turbulence: Turbulence?
        var attractor: Attractor?
        var sizeChange: ParticleChange?
        var alphaChange: ParticleChange?
        var colorChange: ParticleColorChange?
        var angularAcceleration: Float = 0
        var maximumSpeed: Float?
        var vortex: ParticleVortex?
        var boids: ParticleBoids?
        var oscillateSize: ParticleOscillation?
        var oscillateAlpha: ParticleOscillation?
        var oscillatePosition: ParticleOscillation?
        for `operator` in particleSystem.operator ?? [] {
            switch `operator`.name {
            case "movement":
                let value = (`operator`.gravity ?? "0 0 0").parseVector3()
                gravity = SIMD2<Float>(Float(value.0), Float(value.2 != 0 ? value.2 : value.1))
                worldGravity = ((`operator`.flags ?? 0) & 1) != 0
                drag = Float(`operator`.drag ?? 0)
                dragScript = `operator`.$drag.script
            case "alphafade":
                fadeIn = Float(`operator`.fadeintime ?? 0)
                fadeOut = Float(`operator`.fadeouttime ?? 1)
                fadeInScript = `operator`.$fadeintime.script
                fadeOutScript = `operator`.$fadeouttime.script
            case "sizechange":
                sizeChange = ParticleChange(startTime: Float(`operator`.starttime ?? 0),
                                             endTime: Float(`operator`.endtime ?? 1),
                                             startValue: Float(`operator`.startvalue?.doubleValue ?? 1),
                                             endValue: Float(`operator`.endvalue?.doubleValue ?? 1))
            case "alphachange":
                alphaChange = ParticleChange(startTime: Float(`operator`.starttime ?? 0),
                                              endTime: Float(`operator`.endtime ?? 1),
                                              startValue: Float(`operator`.startvalue?.doubleValue ?? 1),
                                              endValue: Float(`operator`.endvalue?.doubleValue ?? 1))
            case "colorchange":
                let start = `operator`.startvalue?.vectorValue ?? (1, 1, 1)
                let end = `operator`.endvalue?.vectorValue ?? (1, 1, 1)
                colorChange = ParticleColorChange(startTime: Float(`operator`.starttime ?? 0),
                                                  endTime: Float(`operator`.endtime ?? 1),
                                                  startValue: SIMD4<Float>(Float(start.0), Float(start.1), Float(start.2), 1),
                                                  endValue: SIMD4<Float>(Float(end.0), Float(end.1), Float(end.2), 1))
            case "angularmovement":
                angularAcceleration = Float((`operator`.force ?? "0 0 0").parseVector3().2)
            case "capvelocity":
                maximumSpeed = Float(`operator`.maxspeed ?? 0)
            case "collisionplane", "collisionsphere", "collisionquad", "collisionbounds":
                if let collision = ParticleCollision(`operator`, sceneSize: sceneSize) { collisions.append(collision) }
            case "collisionmodel":
                OWELog.error(.scene, "Particle system \(particlePath): collisionmodel needs 3D models, not supported; ignored")
            case "vortex", "vortex_v2":
                vortexAudio = ParticleAudioResponse(`operator`) ?? vortexAudio
                vortex = ParticleVortex(innerSpeed: Float(`operator`.speedinner ?? 0),
                                         outerSpeed: Float(`operator`.speedouter ?? 0),
                                         innerDistance: Float(`operator`.distanceinner ?? 0),
                                         outerDistance: Float(`operator`.distanceouter ?? 1000),
                                         controlPoint: `operator`.controlpoint ?? 0)
            case "boids":
                boids = ParticleBoids(alignment: Float(`operator`.alignmentfactor ?? 0),
                                      cohesion: Float(`operator`.cohesionfactor ?? 0),
                                      separation: Float(`operator`.separationfactor ?? 0),
                                      threshold: Float(`operator`.neighborthreshold ?? 150))
            case "oscillatesize":
                oscillateSize = ParticleOscillation(frequency: safeRange(`operator`.frequencymin, `operator`.frequencymax, default: 0),
                                                     scale: safeRange(`operator`.scalemin, `operator`.scalemax, default: 1),
                                                     phase: safeRange(`operator`.phasemin, `operator`.phasemax, default: 0))
            case "oscillatealpha":
                oscillateAlpha = ParticleOscillation(frequency: safeRange(`operator`.frequencymin, `operator`.frequencymax, default: 0),
                                                      scale: safeRange(`operator`.scalemin, `operator`.scalemax, default: 1),
                                                      phase: safeRange(`operator`.phasemin, `operator`.phasemax, default: 0))
            case "oscillateposition":
                oscillatePosition = ParticleOscillation(frequency: safeRange(`operator`.frequencymin, `operator`.frequencymax, default: 0),
                                                         scale: safeRange(`operator`.scalemin, `operator`.scalemax, default: 1),
                                                         phase: safeRange(`operator`.phasemin, `operator`.phasemax, default: 0))
            case "remapvalue":
                if `operator`.output?.lowercased() == "velocity" {
                    let minimum = `operator`.outputrangemin?.vectorValue ?? (0, 0, 0)
                    let maximum = `operator`.outputrangemax?.vectorValue ?? (0, 0, 0)
                    minimumVelocity = SIMD2<Float>(Float(minimum.0), Float(minimum.1))
                    maximumVelocity = SIMD2<Float>(Float(maximum.0), Float(maximum.1))
                } else {
                    remapAlpha = ParticleRemap(scale: Float(`operator`.transforminputscale ?? 1),
                                                outputMinimum: Float(`operator`.outputrangemin?.doubleValue ?? 0),
                                                outputMaximum: Float(`operator`.outputrangemax?.doubleValue ?? 1),
                                                sine: `operator`.transformfunction?.lowercased() == "sine")
                }
            case "reducemovementnearcontrolpoint":
                nearControlPointReduction = ParticleDistanceReduction(offset: .zero,
                                                                       innerDistance: Float(`operator`.distanceinner ?? 0),
                                                                       outerDistance: Float(`operator`.distanceouter ?? 100),
                                                                       reduction: Float(`operator`.reductioninner ?? 1),
                                                                       controlPoint: `operator`.controlpoint ?? 0)
            case "maintaindistancetocontrolpoint":
                maintainControlPointDistance = ParticleDistanceConstraint(offset: .zero,
                                                                          strength: Float(`operator`.variablestrength ?? 1),
                                                                          controlPoint: `operator`.controlpoint ?? 0)
            case "maintaindistancebetweencontrolpoints":
                maintainSequenceDistance = true
            case "inheritvaluefromevent":
                let verbs = inheritance(`operator`.input, default: [.setColor, .setOpacity], element: "inheritvaluefromevent")
                if !verbs.isSubset(of: .eachStep) {
                    OWELog.error(.scene, "Particle system \(particlePath): inheritvaluefromevent can't add \(`operator`.input ?? "") every step; only set and multiply apply")
                }
                inheritEachStep.formUnion(verbs.intersection(.eachStep))
            case "turbulence":
                turbulenceAudio = ParticleAudioResponse(`operator`)
                let mask = `operator`.mask?.vectorValue ?? (1, 1, 0)
                turbulence = Turbulence(scale: Float(`operator`.scale?.doubleValue ?? 0.005),
                                        speed: Float(`operator`.speedmin ?? 500)...Float(`operator`.speedmax ?? 1000),
                                        timeScale: Float(`operator`.timescale ?? 0.01),
                                        phase: Float(`operator`.phasemin ?? 0),
                                        mask: SIMD2<Float>(Float(mask.0), -Float(mask.1)))
            case "controlpointattract":
                // Its "origin" is an offset from its control point, not a scene position.
                let attractOffset = `operator`.origin?.vectorValue ?? (0, 0, 0)
                attractor = Attractor(offset: SIMD2<Float>(Float(attractOffset.0), -Float(attractOffset.1)),
                                      strength: Float(`operator`.scale?.doubleValue ?? 100),
                                      threshold: Float(`operator`.threshold ?? 1000),
                                      controlPoint: `operator`.controlpoint ?? 0)
            default: break
            }
        }
        let refractAmount: Double? = materialPlan != nil ? nil
            : material.passes?.first?.constants?["ui_editor_properties_refract_amount"]?.value
        let opacityMultiplier = refractAmount.map { max(0.04, min(abs(Float($0)), 1)) } ?? 1
        var system = SceneMetalParticleSystem(source: source, origin: origin, emissionRate: max(rate, 0),
                emissionRateScript: rateScript,
                                        maximumParticleCount: max(particleSystem.maxcount ?? 1000, 0),
                                        spawnExtent: spawnExtent, lifetime: lifetime, size: size,
                                        minimumVelocity: minimumVelocity, maximumVelocity: maximumVelocity,
                                        gravity: gravity, drag: drag, dragScript: dragScript, alpha: alpha,
                                        minimumColor: minimumColor, maximumColor: maximumColor,
                                        minimumRotation: minimumRotation, maximumRotation: maximumRotation,
                                        minimumAngularVelocity: minimumAngularVelocity, maximumAngularVelocity: maximumAngularVelocity,
                                        emitterName: emitter?.name ?? "sphererandom",
                                        sizeChange: sizeChange, alphaChange: alphaChange, colorChange: colorChange,
                                        angularAcceleration: angularAcceleration,
                                        maximumSpeed: maximumSpeed, vortex: vortex,
                                        boids: boids,
                                        oscillateSize: oscillateSize, oscillateAlpha: oscillateAlpha,
                                        oscillatePosition: oscillatePosition,
                                        positionOffsetMinimum: positionOffsetMinimum, positionOffsetMaximum: positionOffsetMaximum,
                                        remapAlpha: remapAlpha,
                                        nearControlPointReduction: nearControlPointReduction,
                                        maintainControlPointDistance: maintainControlPointDistance,
                                        controlPoints: controlPoints,
                                        sequenceSpan: sequenceSpan,
                                        sequenceRing: sequenceRing,
                                        initialRemap: initialRemap,
                                        maintainSequenceDistance: maintainSequenceDistance,
                                        rendererName: particleRenderer?.name ?? "sprite",
                                        trailLength: Float(particleRenderer?.maxlength ?? particleRenderer?.length ?? 1),
                                        trailSegments: max(2, particleRenderer?.segments ?? 4),
                                        ropeSubdivision: max(1, particleRenderer?.subdivision ?? 4),
                                        fadeTrailAlpha: particleRenderer?.fadealpha ?? false,
                                        fadeTrailSize: particleRenderer?.fadesize ?? false,
                                        turbulence: turbulence, attractor: attractor,
                                        emitterControlPoint: emitter?.controlpoint,
                                        spriteSheet: spriteSheet,
                                        animationMode: particleSystem.animationmode ?? "sequence",
                                        sequenceMultiplier: Float(particleSystem.sequencemultiplier ?? 1),
                                        opacityMultiplier: opacityMultiplier,
                                        refractive: refractAmount != nil,
                                        fadeIn: fadeIn, fadeOut: fadeOut,
                                        fadeInScript: fadeInScript, fadeOutScript: fadeOutScript,
                                        blending: material.passes?.first?.blending?.lowercased() ?? "translucent")
        system.objectID = object.id.map(String.init)
        system.emitterLinear = world.linear
        system.worldSpace = particleSystem.isWorldSpace
        system.worldGravity = worldGravity
        system.overrides = overrides
        // Bound to user properties: resolved again every frame, so a change shows at once.
        if let instanceOverride = object.instanceoverride,
           instanceOverride.values.values.contains(where: { $0.userBindingSource != nil }) {
            system.liveOverrides = instanceOverride
        }
        system.collisions = collisions
        system.rateAudio = emitter.flatMap { ParticleAudioResponse($0) }
        system.velocityAudio = velocityAudio
        system.audioVelocityMinimum = audioVelocityMinimum
        system.audioVelocityMaximum = audioVelocityMaximum
        system.turbulenceAudio = turbulenceAudio
        system.vortexAudio = vortexAudio
        system.inheritOnSpawn = inheritOnSpawn
        system.inheritEachStep = inheritEachStep
        if let emitter {
            system.instantaneous = max(emitter.instantaneous ?? 0, 0)
            system.emitterTiming = ParticleEmitterTiming(emitter)
            let speeds = (Float(emitter.speedmin ?? 0), Float(emitter.speedmax ?? emitter.speedmin ?? 0))
            system.emitterSpeed = min(speeds.0, speeds.1)...max(speeds.0, speeds.1)
            let sign = emitter.sign?.vectorValue ?? (0, 0, 0)
            system.emitterSign = SIMD2(Float(sign.0), Float(sign.1))
            let innerDistance = Float(emitter.distancemin?.vectorValue.0 ?? 0)
            system.minimumSpawnRatio = distance.0 > 0 ? min(max(innerDistance / Float(distance.0), 0), 1) : 0
        }
        return system
    }

    private static func safeRange(_ min: Double?, _ max: Double?, default defaultValue: Float) -> ClosedRange<Float> {
        let lower = Float(min ?? Double(defaultValue))
        let upper = Float(max ?? Double(defaultValue))
        return Swift.min(lower, upper)...Swift.max(lower, upper)
    }

    private static func normalizedParticleColor(_ color: (Double, Double, Double)) -> SIMD4<Float> {
        guard color.0.isFinite, color.1.isFinite, color.2.isFinite,
              max(color.0, color.1, color.2) > 0 else {
            return SIMD4<Float>(1, 1, 1, 1)
        }
        let scale = max(color.0, color.1, color.2) > 1 ? 255.0 : 1.0
        return SIMD4<Float>(Float(color.0 / scale), Float(color.1 / scale), Float(color.2 / scale), 1)
    }
}
