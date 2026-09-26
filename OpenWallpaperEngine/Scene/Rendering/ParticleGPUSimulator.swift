import Metal

/// Runs particle systems on the GPU (`ParticleSimulation.metal`): one compute pass per frame
/// steps every system and writes its draw records and indirect draw arguments, so neither the
/// particles nor their count come back to the CPU. The CPU only evaluates the frame's inputs
/// (`ParticleFrameInputs`).
final class ParticleGPUSimulator {
    /// One system's step this frame.
    struct Request {
        let system: ParticleSystemRuntime
        let inputs: ParticleFrameInputs
        /// What the step writes records for.
        let kind: ParticleGPUDrawKind
        /// The material draw's vertices per instance (ignored for the built-in draw).
        var materialVertexCount = 0
        /// A rope material's uniform block: the step writes `g_RenderVar0` (the point count) at
        /// this byte offset.
        var renderVar: (buffer: MTLBuffer, offset: Int)?
    }

    static let threadgroupSize = 256

    private let device: MTLDevice
    private let age, begin, emit, simulate, scanBlocks, scanBlockSums, compact, finish: MTLComputePipelineState
    private let emitSerial, simulateSerial: MTLComputePipelineState
    private let eventMark, eventScatter, instanceStep, linkPoints: MTLComputePipelineState
    private let writers: [ParticleGPUDrawKind: MTLComputePipelineState]

    init(device: MTLDevice) throws {
        let library = try device.makeDefaultLibrary(bundle: Bundle(for: ParticleGPUSimulator.self))
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw ShaderCompilerError.failed(step: "metal", output: "kernel \(name) missing")
            }
            return try device.makeComputePipelineState(function: function)
        }
        self.device = device
        age = try pipeline("particleAge")
        begin = try pipeline("particleBegin")
        emit = try pipeline("particleEmit")
        simulate = try pipeline("particleSimulate")
        emitSerial = try pipeline("particleEmitSerial")
        simulateSerial = try pipeline("particleSimulateSerial")
        scanBlocks = try pipeline("particleScanBlocks")
        scanBlockSums = try pipeline("particleScanBlockSums")
        compact = try pipeline("particleCompact")
        finish = try pipeline("particleFinish")
        eventMark = try pipeline("particleEventMark")
        eventScatter = try pipeline("particleEventScatter")
        instanceStep = try pipeline("particleInstanceStep")
        linkPoints = try pipeline("particleLinkPoints")
        let sprites = try pipeline("particleWriteFallbackSprites")
        writers = [
            .sprite: try pipeline("particleWriteSprites"),
            .rope: try pipeline("particleWriteRope"),
            .ropeTrail: try pipeline("particleWriteRopeTrails"),
            .fallbackSprite: sprites,
            .fallbackSpriteTrail: sprites,
            .fallbackRope: try pipeline("particleWriteFallbackRope"),
            .fallbackRopeTrail: try pipeline("particleWriteFallbackRopeTrails"),
        ]
    }

    /// The system's GPU state, made on first use. Nil when its buffers can't be allocated.
    func state(for system: ParticleSystemRuntime) -> ParticleGPUSystem? {
        if let gpu = system.gpu { return gpu }
        system.gpu = ParticleGPUSystem(device: device, configuration: system.configuration, seed: system.seed)
        return system.gpu
    }

    /// Encodes every request's step into `commandBuffer`. Systems whose buffers can't grow are
    /// skipped (logged) and draw nothing this frame.
    func encode(_ requests: [Request], sceneSize: SIMD2<Float>, targetSize: SIMD2<Float>,
                commandBuffer: MTLCommandBuffer) {
        guard !requests.isEmpty else { return }
        var blit: MTLBlitCommandEncoder?
        for request in requests {
            guard let gpu = state(for: request.system) else { continue }
            gpu.isReady = gpu.reserve(for: request.inputs) {
                if blit == nil { blit = commandBuffer.makeBlitCommandEncoder() }
                return blit
            }
            // An instanced or linked system steps from its parent's step, encoded just before it.
            let configuration = request.system.configuration
            if gpu.isReady, configuration.isInstanced || configuration.link?.controlPointStart != nil {
                let parent = request.system.parent?.gpu
                gpu.isReady = parent?.isReady == true
                if let parent, gpu.isReady, request.system.configuration.link?.kind != .static {
                    gpu.isReady = gpu.reserveEvents(parentCapacity: parent.capacity)
                }
            }
            if !gpu.isReady, !gpu.reportedFailure {
                gpu.reportedFailure = true
                OWELog.error(.scene, "Particle system can't grow its GPU buffers past \(gpu.capacity) particles; skipped")
            }
        }
        blit?.endEncoding()
        // Every system's steps go stage by stage, all systems of a wave at once: dispatches of one
        // stage run concurrently and one barrier separates the stages, instead of each small
        // system's dozen dispatches running one after another. A system's next request and a
        // child's first run a wave after their parent's (they read its particles and events).
        var plans: [[StepPlan]] = []
        var lastWave: [ObjectIdentifier: Int] = [:]
        for request in requests {
            guard let gpu = request.system.gpu, gpu.isReady,
                  let plan = StepPlan(request, gpu: gpu, sceneSize: sceneSize, targetSize: targetSize) else { continue }
            let own = lastWave[ObjectIdentifier(request.system)].map { $0 + 1 } ?? 0
            let parent = request.system.parent.flatMap { lastWave[ObjectIdentifier($0)] }.map { $0 + 1 } ?? 0
            let wave = max(own, parent)
            lastWave[ObjectIdentifier(request.system)] = wave
            while plans.count <= wave { plans.append([]) }
            plans[wave].append(plan)
        }
        guard !plans.isEmpty, let encoder = commandBuffer.makeComputeCommandEncoder(dispatchType: .concurrent) else { return }
        encoder.label = "Particle simulation"
        for wave in plans {
            for stage in Stage.allCases {
                var encoded = false
                for plan in wave where encode(stage, plan, encoder: encoder) { encoded = true }
                if encoded { encoder.memoryBarrier(scope: .buffers) }
            }
        }
        encoder.endEncoding()
    }

    /// The dispatches of a system's step, in order; each reads what the ones before it wrote.
    private enum Stage: CaseIterable {
        case linkPoints, age, eventMark, eventScanBlocks, eventScanSums, eventScatter, begin, emit, simulate
        case scanBlocks, scanSums, compact, trailScanBlocks, trailScanSums, finish, write
    }

    /// One request's step: its buffers and frame, captured when the frame is encoded.
    private struct StepPlan {
        let request: Request
        let gpu: ParticleGPUSystem
        let parent: ParticleGPUSystem?
        var frame: ParticleGPUFrame
        let particles, stepped, alive, offsets, blockSums, records: MTLBuffer
        let history, nextHistory, trailCounts, instances, linked: MTLBuffer
        /// The initializers, then the operators (`ParticleProgramOp`).
        let program: [ParticleProgramOp]
        let steps: [ParticleGPUEmitterStep]
        let trails: Bool
        /// Spawns and steps in one thread (`ParticleGPUSystem.writesControlPoints`).
        let serialPoints: MTLBuffer?

        init?(_ request: Request, gpu: ParticleGPUSystem, sceneSize: SIMD2<Float>, targetSize: SIMD2<Float>) {
            let configuration = request.system.configuration
            let subdivision = max(configuration.ropeSubdivision, 1)
            guard let particles = gpu.particles, let stepped = gpu.stepped, let alive = gpu.alive,
                  let offsets = gpu.offsets, let blockSums = gpu.blockSums,
                  let records = gpu.recordBuffer(for: request.kind, subdivision: subdivision) else { return nil }
            parent = request.system.parent?.gpu
            if configuration.isInstanced, parent == nil { return nil }
            self.request = request
            self.gpu = gpu
            frame = ParticleGPUFrame(request.inputs, sceneSize: sceneSize, targetSize: targetSize, kind: request.kind,
                                     materialVertexCount: request.materialVertexCount,
                                     renderVarOffset: request.renderVar?.offset)
            frame.emission.y = UInt32(gpu.emitterCount)
            let ropeUV = configuration.ropeUV
            frame.rope = SIMD4(ropeUV.rate * request.inputs.ropeRateScale, ropeUV.lifetime * request.inputs.ropeLifetimeScale,
                               Float(request.inputs.frameRateLimit), ropeUV.inverseScale)
            self.particles = particles
            self.stepped = stepped
            self.alive = alive
            self.offsets = offsets
            self.blockSums = blockSums
            self.records = records
            // Buffers a system without trails never touches still need a binding.
            history = gpu.history[gpu.historyIndex] ?? gpu.control
            nextHistory = gpu.history[gpu.historyIndex ^ 1] ?? gpu.control
            gpu.toggleHistory()
            trailCounts = gpu.trailCounts ?? gpu.control
            instances = gpu.instances ?? gpu.control
            linked = gpu.linkedPoints ?? gpu.control
            program = request.inputs.initializers + request.inputs.operators
            var steps = request.inputs.emitters.prefix(gpu.emitterCount).map(ParticleGPUEmitterStep.init)
            while steps.count < max(gpu.emitterCount, 1) { steps.append(ParticleGPUEmitterStep(ParticleEmitterStep())) }
            self.steps = steps
            trails = request.kind == .ropeTrail || request.kind == .fallbackRopeTrail
            serialPoints = gpu.writesControlPoints ? gpu.pointStates : nil
        }
    }

    /// Encodes `plan`'s dispatch for `stage`; false when the stage has none for it.
    private func encode(_ stage: Stage, _ plan: StepPlan, encoder: MTLComputeCommandEncoder) -> Bool {
        let gpu = plan.gpu, control = gpu.control
        var frame = plan.frame
        let frameLength = MemoryLayout<ParticleGPUFrame>.stride
        let group = MTLSize(width: Self.threadgroupSize, height: 1, depth: 1)
        let single = MTLSize(width: 1, height: 1, depth: 1)
        func perParticle() {
            encoder.dispatchThreadgroups(indirectBuffer: control, indirectBufferOffset: ParticleGPUSystem.Control.dispatchOffset,
                                         threadsPerThreadgroup: group)
        }
        let configuration = plan.request.system.configuration
        let isEventChild = configuration.isInstanced && configuration.link?.kind != .static
        switch stage {
        case .linkPoints:
            guard let linkedPoints = gpu.linkedPoints, let parent = plan.parent, let parentParticles = parent.particles else {
                return false
            }
            var slots = UInt32(gpu.slots)
            encoder.setComputePipelineState(linkPoints)
            encoder.setBuffer(parentParticles, offset: 0, index: 0)
            encoder.setBuffer(parent.control, offset: 0, index: 1)
            encoder.setBuffer(linkedPoints, offset: 0, index: 2)
            encoder.setBuffer(gpu.parameters, offset: 0, index: 3)
            encoder.setBytes(&slots, length: 4, index: 4)
            encoder.dispatchThreads(MTLSize(width: gpu.slots, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: min(gpu.slots, 64), height: 1, depth: 1))
        case .age:
            // WE's order: every particle ages first and those past their lifetime die (0x140236d91).
            encoder.setComputePipelineState(age)
            encoder.setBuffer(plan.particles, offset: 0, index: 0)
            encoder.setBuffer(plan.alive, offset: 0, index: 1)
            encoder.setBuffer(control, offset: 0, index: 2)
            encoder.setBuffer(gpu.parameters, offset: 0, index: 3)
            encoder.setBytes(&frame, length: frameLength, index: 4)
            encoder.setBuffer(plan.instances, offset: 0, index: 5)
            perParticle()
        case .eventMark, .eventScanBlocks, .eventScanSums, .eventScatter:
            guard isEventChild, let parent = plan.parent, let parentStepped = parent.stepped, let parentAlive = parent.alive,
                  let flags = gpu.eventFlags, let offsets = gpu.eventOffsets, let blockSums = gpu.eventBlockSums,
                  let events = gpu.events else { return false }
            let perParentParticle = {
                encoder.dispatchThreadgroups(indirectBuffer: parent.control, indirectBufferOffset: ParticleGPUSystem.Control.dispatchOffset,
                                             threadsPerThreadgroup: group)
            }
            switch stage {
            case .eventMark:
                encoder.setComputePipelineState(eventMark)
                encoder.setBuffer(parentStepped, offset: 0, index: 0)
                encoder.setBuffer(parentAlive, offset: 0, index: 1)
                encoder.setBuffer(parent.control, offset: 0, index: 2)
                encoder.setBuffer(flags, offset: 0, index: 3)
                encoder.setBuffer(gpu.parameters, offset: 0, index: 4)
                perParentParticle()
            case .eventScanBlocks:
                scanBlocks(flags, count: ParticleGPUSystem.Control.total, offsets: offsets, blockSums: blockSums,
                           control: parent.control, encoder: encoder)
            case .eventScanSums:
                scanSums(count: ParticleGPUSystem.Control.total, into: ParticleGPUSystem.Control.eventTotal, blockSums: blockSums,
                         control: parent.control, totals: control, encoder: encoder)
            default:
                encoder.setComputePipelineState(eventScatter)
                encoder.setBuffer(flags, offset: 0, index: 0)
                encoder.setBuffer(offsets, offset: 0, index: 1)
                encoder.setBuffer(blockSums, offset: 0, index: 2)
                encoder.setBuffer(parent.control, offset: 0, index: 3)
                encoder.setBuffer(events, offset: 0, index: 4)
                perParentParticle()
            }
        case .begin:
            if configuration.isInstanced {
                guard let parent = plan.parent, let instances = gpu.instances, let parentStepped = parent.stepped,
                      let parentParticles = parent.particles else { return false }
                encoder.setComputePipelineState(instanceStep)
                encoder.setBuffer(control, offset: 0, index: 0)
                encoder.setBuffer(instances, offset: 0, index: 1)
                encoder.setBuffer(gpu.parameters, offset: 0, index: 2)
                encoder.setBytes(&frame, length: frameLength, index: 3)
                encoder.setBuffer(parentStepped, offset: 0, index: 4)
                encoder.setBuffer(parentParticles, offset: 0, index: 5)
                encoder.setBuffer(parent.control, offset: 0, index: 6)
                encoder.setBuffer(gpu.events ?? control, offset: 0, index: 7)
                encoder.setBuffer(parent.instances ?? control, offset: 0, index: 8)
                encoder.setBuffer(gpu.emitterParameters, offset: 0, index: 9)
                bindEmitterSteps(plan.steps, index: 10, encoder: encoder)
                encoder.setBuffer(gpu.emitterStates, offset: 0, index: 11)
            } else {
                encoder.setComputePipelineState(begin)
                encoder.setBuffer(control, offset: 0, index: 0)
                encoder.setBuffer(gpu.parameters, offset: 0, index: 1)
                encoder.setBytes(&frame, length: frameLength, index: 2)
                bindEmitterSteps(plan.steps, index: 3, encoder: encoder)
                encoder.setBuffer(gpu.emitterStates, offset: 0, index: 4)
            }
            encoder.dispatchThreads(single, threadsPerThreadgroup: single)
        case .emit:
            // A program that writes control points spawns and steps in one thread, in WE's order.
            encoder.setComputePipelineState(plan.serialPoints == nil ? emit : emitSerial)
            encoder.setBuffer(plan.particles, offset: 0, index: 0)
            encoder.setBuffer(control, offset: 0, index: 1)
            encoder.setBuffer(gpu.parameters, offset: 0, index: 2)
            encoder.setBytes(&frame, length: frameLength, index: 3)
            encoder.setBuffer(plan.instances, offset: 0, index: 4)
            encoder.setBuffer(plan.linked, offset: 0, index: 5)
            bindProgram(plan.program, index: 6, fallback: control, encoder: encoder)
            encoder.setBuffer(gpu.emitterParameters, offset: 0, index: 7)
            encoder.setBuffer(gpu.emitterStates, offset: 0, index: 8)
            if let serialPoints = plan.serialPoints {
                encoder.setBuffer(serialPoints, offset: 0, index: 9)
                encoder.dispatchThreads(single, threadsPerThreadgroup: single)
            } else {
                perParticle()
            }
        case .simulate:
            encoder.setComputePipelineState(plan.serialPoints == nil ? simulate : simulateSerial)
            encoder.setBuffer(plan.particles, offset: 0, index: 0)
            encoder.setBuffer(plan.stepped, offset: 0, index: 1)
            encoder.setBuffer(plan.alive, offset: 0, index: 2)
            encoder.setBuffer(plan.history, offset: 0, index: 3)
            encoder.setBuffer(control, offset: 0, index: 4)
            encoder.setBuffer(gpu.parameters, offset: 0, index: 5)
            encoder.setBytes(&frame, length: frameLength, index: 6)
            encoder.setBuffer(plan.instances, offset: 0, index: 7)
            let collisions = plan.request.inputs.collisions
            let collisionBytes = collisions.count * MemoryLayout<ParticleCollisionPlacement>.stride
            if collisions.isEmpty {
                encoder.setBuffer(control, offset: 0, index: 8)
            } else if collisionBytes <= 4096 {
                collisions.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: collisionBytes, index: 8) }
            } else if let buffer = device.makeBuffer(bytes: collisions, length: collisionBytes, options: .storageModeShared) {
                encoder.setBuffer(buffer, offset: 0, index: 8)
            } else {
                encoder.setBuffer(control, offset: 0, index: 8)
            }
            encoder.setBuffer(plan.linked, offset: 0, index: 9)
            bindProgram(plan.program, index: 10, fallback: control, encoder: encoder)
            if let serialPoints = plan.serialPoints, let serialStates = gpu.serialStates {
                encoder.setBuffer(serialPoints, offset: 0, index: 11)
                encoder.setBuffer(serialStates, offset: 0, index: 12)
                encoder.dispatchThreads(single, threadsPerThreadgroup: single)
            } else {
                perParticle()
            }
        case .scanBlocks:
            scanBlocks(plan.alive, count: ParticleGPUSystem.Control.total, offsets: plan.offsets, blockSums: plan.blockSums,
                       control: control, encoder: encoder)
        case .scanSums:
            scanSums(count: ParticleGPUSystem.Control.total, into: ParticleGPUSystem.Control.count, blockSums: plan.blockSums,
                     control: control, totals: control, encoder: encoder)
        case .compact:
            encoder.setComputePipelineState(compact)
            encoder.setBuffer(plan.stepped, offset: 0, index: 0)
            encoder.setBuffer(plan.particles, offset: 0, index: 1)
            encoder.setBuffer(plan.alive, offset: 0, index: 2)
            encoder.setBuffer(plan.offsets, offset: 0, index: 3)
            encoder.setBuffer(plan.blockSums, offset: 0, index: 4)
            encoder.setBuffer(plan.history, offset: 0, index: 5)
            encoder.setBuffer(plan.nextHistory, offset: 0, index: 6)
            encoder.setBuffer(plan.trailCounts, offset: 0, index: 7)
            encoder.setBuffer(control, offset: 0, index: 8)
            encoder.setBuffer(gpu.parameters, offset: 0, index: 9)
            perParticle()
        case .trailScanBlocks:
            guard plan.trails else { return false }
            scanBlocks(plan.trailCounts, count: ParticleGPUSystem.Control.count, offsets: plan.offsets, blockSums: plan.blockSums,
                       control: control, encoder: encoder)
        case .trailScanSums:
            guard plan.trails else { return false }
            scanSums(count: ParticleGPUSystem.Control.count, into: ParticleGPUSystem.Control.trailTotal, blockSums: plan.blockSums,
                     control: control, totals: control, encoder: encoder)
        case .finish:
            encoder.setComputePipelineState(finish)
            encoder.setBuffer(control, offset: 0, index: 0)
            encoder.setBuffer(plan.request.renderVar?.buffer ?? control, offset: 0, index: 1)
            encoder.setBuffer(gpu.parameters, offset: 0, index: 2)
            encoder.setBytes(&frame, length: frameLength, index: 3)
            encoder.dispatchThreads(single, threadsPerThreadgroup: single)
        case .write:
            guard let writer = writers[plan.request.kind] else { return false }
            encoder.setComputePipelineState(writer)
            encoder.setBuffer(plan.particles, offset: 0, index: 0)
            encoder.setBuffer(plan.records, offset: 0, index: 1)
            if plan.trails {
                encoder.setBuffer(plan.nextHistory, offset: 0, index: 2)
                encoder.setBuffer(plan.offsets, offset: 0, index: 3)
                encoder.setBuffer(plan.blockSums, offset: 0, index: 4)
                encoder.setBuffer(control, offset: 0, index: 5)
                encoder.setBuffer(gpu.parameters, offset: 0, index: 6)
                encoder.setBytes(&frame, length: frameLength, index: 7)
            } else {
                encoder.setBuffer(control, offset: 0, index: 2)
                encoder.setBuffer(gpu.parameters, offset: 0, index: 3)
                encoder.setBytes(&frame, length: frameLength, index: 4)
            }
            perParticle()
        }
        return true
    }

    /// The step's program (`ParticleProgramOp`: initializers, then operators) at `index`.
    private func bindProgram(_ records: [ParticleProgramOp], index: Int, fallback: MTLBuffer, encoder: MTLComputeCommandEncoder) {
        let bytes = records.count * MemoryLayout<ParticleProgramOp>.stride
        if records.isEmpty {
            encoder.setBuffer(fallback, offset: 0, index: index)
        } else if bytes <= 4096 {
            records.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: bytes, index: index) }
        } else if let buffer = device.makeBuffer(bytes: records, length: bytes, options: .storageModeShared) {
            encoder.setBuffer(buffer, offset: 0, index: index)
        } else {
            encoder.setBuffer(fallback, offset: 0, index: index)
        }
    }

    /// The step's emitters (`ParticleGPUEmitterStep`) at `index`.
    private func bindEmitterSteps(_ steps: [ParticleGPUEmitterStep], index: Int, encoder: MTLComputeCommandEncoder) {
        steps.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: index) }
    }

    /// Per-group prefix sums of `values` (`control[count]` of them) into `offsets` and `blockSums`.
    private func scanBlocks(_ values: MTLBuffer, count: Int, offsets: MTLBuffer, blockSums: MTLBuffer, control: MTLBuffer,
                            encoder: MTLComputeCommandEncoder) {
        var countIndex = UInt32(count)
        encoder.setComputePipelineState(scanBlocks)
        encoder.setBuffer(values, offset: 0, index: 0)
        encoder.setBuffer(offsets, offset: 0, index: 1)
        encoder.setBuffer(blockSums, offset: 0, index: 2)
        encoder.setBuffer(control, offset: 0, index: 3)
        encoder.setBytes(&countIndex, length: 4, index: 4)
        encoder.dispatchThreadgroups(indirectBuffer: control, indirectBufferOffset: ParticleGPUSystem.Control.dispatchOffset,
                                     threadsPerThreadgroup: MTLSize(width: Self.threadgroupSize, height: 1, depth: 1))
    }

    /// The groups' offsets from `scanBlocks`' totals, and the grand total into `totals[total]`.
    private func scanSums(count: Int, into total: Int, blockSums: MTLBuffer, control: MTLBuffer, totals: MTLBuffer,
                          encoder: MTLComputeCommandEncoder) {
        var indices = SIMD2<UInt32>(UInt32(count), UInt32(total))
        encoder.setComputePipelineState(scanBlockSums)
        encoder.setBuffer(blockSums, offset: 0, index: 0)
        encoder.setBuffer(control, offset: 0, index: 1)
        encoder.setBytes(&indices, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 2)
        encoder.setBuffer(totals, offset: 0, index: 3)
        encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: Self.threadgroupSize, height: 1, depth: 1))
    }

    /// An instanced system's instances after the last committed step (tests). Blocks until the
    /// GPU is done.
    func instances(_ system: ParticleSystemRuntime, queue: MTLCommandQueue) -> [ParticleGPUInstance] {
        guard let gpu = system.gpu, let instances = gpu.instances else { return [] }
        if let commandBuffer = queue.makeCommandBuffer() {
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }
        let count = instances.length / MemoryLayout<ParticleGPUInstance>.stride
        let pointer = instances.contents().bindMemory(to: ParticleGPUInstance.self, capacity: count)
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    /// The particles of `system` after the last committed step, in order (tests, diagnostics).
    /// Blocks until the GPU is done.
    func snapshot(_ system: ParticleSystemRuntime, queue: MTLCommandQueue) -> [ParticleGPUState] {
        guard let gpu = system.gpu, let particles = gpu.particles else { return [] }
        return readBack(particles, as: ParticleGPUState.self, count: min(gpu.completedCount, gpu.capacity), queue: queue)
    }

    /// The history samples of a `ropetrail` particle from `snapshot`, oldest first (tests).
    func history(_ system: ParticleSystemRuntime, particle state: ParticleGPUState, index: Int,
                 queue: MTLCommandQueue) -> [SIMD2<Float>] {
        guard let gpu = system.gpu, let history = gpu.history[gpu.historyIndex] else { return [] }
        let count = Int(state.identity.z), start = Int(state.identity.w)
        let own = readBack(history, as: SIMD2<Float>.self, count: (index + 1) * gpu.historyLimit, queue: queue)
            .suffix(gpu.historyLimit)
        return (0..<count).map { own[own.startIndex + (start + $0) % count] }
    }

    /// The last step's records (tests): `count` of them, and the indirect draw arguments.
    func records<Record>(_ system: ParticleSystemRuntime, as type: Record.Type,
                         queue: MTLCommandQueue) -> (records: [Record], material: [UInt32], fallback: [UInt32]) {
        guard let gpu = system.gpu, let records = gpu.records else { return ([], [], []) }
        let words = gpu.control.contents().bindMemory(to: UInt32.self, capacity: ParticleGPUSystem.Control.words)
        let material = (0..<4).map { words[ParticleGPUSystem.Control.materialDrawOffset / 4 + $0] }
        let fallback = (0..<4).map { words[ParticleGPUSystem.Control.fallbackDrawOffset / 4 + $0] }
        let count = Int(gpu.recordKind?.isFallback == true ? fallback[1] : material[1])
        return (readBack(records, as: type, count: count, queue: queue), material, fallback)
    }

    private func readBack<Element>(_ buffer: MTLBuffer, as type: Element.Type, count: Int,
                                   queue: MTLCommandQueue) -> [Element] {
        let bytes = min(count * MemoryLayout<Element>.stride, buffer.length)
        guard bytes > 0, let commandBuffer = queue.makeCommandBuffer(),
              let staging = device.makeBuffer(length: bytes, options: .storageModeShared),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return [] }
        blit.copy(from: buffer, sourceOffset: 0, to: staging, destinationOffset: 0, size: bytes)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let elements = staging.contents().bindMemory(to: Element.self, capacity: bytes / MemoryLayout<Element>.stride)
        return Array(UnsafeBufferPointer(start: elements, count: bytes / MemoryLayout<Element>.stride))
    }
}
