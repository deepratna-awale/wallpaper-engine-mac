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
    private let begin, emit, simulate, scanBlocks, scanBlockSums, compact, finish: MTLComputePipelineState
    private let eventMark, eventScatter, instanceStep: MTLComputePipelineState
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
        begin = try pipeline("particleBegin")
        emit = try pipeline("particleEmit")
        simulate = try pipeline("particleSimulate")
        scanBlocks = try pipeline("particleScanBlocks")
        scanBlockSums = try pipeline("particleScanBlockSums")
        compact = try pipeline("particleCompact")
        finish = try pipeline("particleFinish")
        eventMark = try pipeline("particleEventMark")
        eventScatter = try pipeline("particleEventScatter")
        instanceStep = try pipeline("particleInstanceStep")
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
            // An instanced system steps from its parent's step, encoded just before it.
            if gpu.isReady, request.system.configuration.isInstanced {
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
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "Particle simulation"
        for request in requests {
            guard let gpu = request.system.gpu, gpu.isReady else { continue }
            encode(request, gpu: gpu, sceneSize: sceneSize, targetSize: targetSize, encoder: encoder)
        }
        encoder.endEncoding()
    }

    private func encode(_ request: Request, gpu: ParticleGPUSystem, sceneSize: SIMD2<Float>, targetSize: SIMD2<Float>,
                        encoder: MTLComputeCommandEncoder) {
        let subdivision = max(request.system.configuration.ropeSubdivision, 1)
        guard let particles = gpu.particles, let stepped = gpu.stepped, let alive = gpu.alive,
              let offsets = gpu.offsets, let blockSums = gpu.blockSums,
              let records = gpu.recordBuffer(for: request.kind, subdivision: subdivision) else { return }
        var frame = ParticleGPUFrame(request.inputs, sceneSize: sceneSize, targetSize: targetSize, kind: request.kind,
                                     materialVertexCount: request.materialVertexCount,
                                     renderVarOffset: request.renderVar?.offset)
        let frameLength = MemoryLayout<ParticleGPUFrame>.stride
        let control = gpu.control
        // Buffers a system without trails never touches still need a binding.
        let history = gpu.history[gpu.historyIndex] ?? control
        let nextHistory = gpu.history[gpu.historyIndex ^ 1] ?? control
        let trailCounts = gpu.trailCounts ?? control
        let group = MTLSize(width: Self.threadgroupSize, height: 1, depth: 1)
        let single = MTLSize(width: 1, height: 1, depth: 1)
        func perParticle() {
            encoder.dispatchThreadgroups(indirectBuffer: control, indirectBufferOffset: ParticleGPUSystem.Control.dispatchOffset,
                                         threadsPerThreadgroup: group)
        }
        let instances = gpu.instances ?? control

        if request.system.configuration.isInstanced {
            guard let parent = request.system.parent?.gpu else { return }
            encodeInstanceStep(request.system, gpu: gpu, parent: parent, frame: &frame, encoder: encoder)
        } else {
            encoder.setComputePipelineState(begin)
            encoder.setBuffer(control, offset: 0, index: 0)
            encoder.setBuffer(gpu.parameters, offset: 0, index: 1)
            encoder.setBytes(&frame, length: frameLength, index: 2)
            encoder.dispatchThreads(single, threadsPerThreadgroup: single)
        }

        encoder.setComputePipelineState(emit)
        encoder.setBuffer(particles, offset: 0, index: 0)
        encoder.setBuffer(control, offset: 0, index: 1)
        encoder.setBuffer(gpu.parameters, offset: 0, index: 2)
        encoder.setBytes(&frame, length: frameLength, index: 3)
        encoder.setBuffer(instances, offset: 0, index: 4)
        perParticle()

        encoder.setComputePipelineState(simulate)
        encoder.setBuffer(particles, offset: 0, index: 0)
        encoder.setBuffer(stepped, offset: 0, index: 1)
        encoder.setBuffer(alive, offset: 0, index: 2)
        encoder.setBuffer(history, offset: 0, index: 3)
        encoder.setBuffer(control, offset: 0, index: 4)
        encoder.setBuffer(gpu.parameters, offset: 0, index: 5)
        encoder.setBytes(&frame, length: frameLength, index: 6)
        encoder.setBuffer(instances, offset: 0, index: 7)
        perParticle()

        scan(alive, count: ParticleGPUSystem.Control.total, into: ParticleGPUSystem.Control.count, offsets: offsets,
             blockSums: blockSums, control: control, encoder: encoder)

        encoder.setComputePipelineState(compact)
        encoder.setBuffer(stepped, offset: 0, index: 0)
        encoder.setBuffer(particles, offset: 0, index: 1)
        encoder.setBuffer(alive, offset: 0, index: 2)
        encoder.setBuffer(offsets, offset: 0, index: 3)
        encoder.setBuffer(blockSums, offset: 0, index: 4)
        encoder.setBuffer(history, offset: 0, index: 5)
        encoder.setBuffer(nextHistory, offset: 0, index: 6)
        encoder.setBuffer(trailCounts, offset: 0, index: 7)
        encoder.setBuffer(control, offset: 0, index: 8)
        encoder.setBuffer(gpu.parameters, offset: 0, index: 9)
        perParticle()
        gpu.toggleHistory()

        let trails = request.kind == .ropeTrail || request.kind == .fallbackRopeTrail
        if trails {
            scan(trailCounts, count: ParticleGPUSystem.Control.count, into: ParticleGPUSystem.Control.trailTotal,
                 offsets: offsets, blockSums: blockSums, control: control, encoder: encoder)
        }

        encoder.setComputePipelineState(finish)
        encoder.setBuffer(control, offset: 0, index: 0)
        encoder.setBuffer(request.renderVar?.buffer ?? control, offset: 0, index: 1)
        encoder.setBuffer(gpu.parameters, offset: 0, index: 2)
        encoder.setBytes(&frame, length: frameLength, index: 3)
        encoder.dispatchThreads(single, threadsPerThreadgroup: single)

        guard let writer = writers[request.kind] else { return }
        encoder.setComputePipelineState(writer)
        if trails {
            encoder.setBuffer(particles, offset: 0, index: 0)
            encoder.setBuffer(records, offset: 0, index: 1)
            encoder.setBuffer(nextHistory, offset: 0, index: 2)
            encoder.setBuffer(offsets, offset: 0, index: 3)
            encoder.setBuffer(blockSums, offset: 0, index: 4)
            encoder.setBuffer(control, offset: 0, index: 5)
            encoder.setBuffer(gpu.parameters, offset: 0, index: 6)
            encoder.setBytes(&frame, length: frameLength, index: 7)
        } else {
            encoder.setBuffer(particles, offset: 0, index: 0)
            encoder.setBuffer(records, offset: 0, index: 1)
            encoder.setBuffer(control, offset: 0, index: 2)
            encoder.setBuffer(gpu.parameters, offset: 0, index: 3)
            encoder.setBytes(&frame, length: frameLength, index: 4)
        }
        perParticle()
    }

    /// Prefix sums of `values` (`countControl[count]` of them) into `offsets` and `blockSums`, the
    /// total into `totals[total]` (`countControl` by default).
    private func scan(_ values: MTLBuffer, count: Int, into total: Int, offsets: MTLBuffer, blockSums: MTLBuffer,
                      control countControl: MTLBuffer, totals: MTLBuffer? = nil, encoder: MTLComputeCommandEncoder) {
        let group = MTLSize(width: Self.threadgroupSize, height: 1, depth: 1)
        var countIndex = UInt32(count)
        encoder.setComputePipelineState(scanBlocks)
        encoder.setBuffer(values, offset: 0, index: 0)
        encoder.setBuffer(offsets, offset: 0, index: 1)
        encoder.setBuffer(blockSums, offset: 0, index: 2)
        encoder.setBuffer(countControl, offset: 0, index: 3)
        encoder.setBytes(&countIndex, length: 4, index: 4)
        encoder.dispatchThreadgroups(indirectBuffer: countControl, indirectBufferOffset: ParticleGPUSystem.Control.dispatchOffset,
                                     threadsPerThreadgroup: group)
        var indices = SIMD2<UInt32>(UInt32(count), UInt32(total))
        encoder.setComputePipelineState(scanBlockSums)
        encoder.setBuffer(blockSums, offset: 0, index: 0)
        encoder.setBuffer(countControl, offset: 0, index: 1)
        encoder.setBytes(&indices, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 2)
        encoder.setBuffer(totals ?? countControl, offset: 0, index: 3)
        encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: group)
    }

    /// An instanced system's `particleBegin`: its parent's events (event children), then its
    /// instances and emission (`ParticleInstances.metal`).
    private func encodeInstanceStep(_ system: ParticleSystemRuntime, gpu: ParticleGPUSystem, parent: ParticleGPUSystem,
                                    frame: inout ParticleGPUFrame, encoder: MTLComputeCommandEncoder) {
        guard let instances = gpu.instances, let parentStepped = parent.stepped, let parentParticles = parent.particles,
              let parentAlive = parent.alive else { return }
        let group = MTLSize(width: Self.threadgroupSize, height: 1, depth: 1)
        let perParentParticle = { encoder.dispatchThreadgroups(indirectBuffer: parent.control,
                                                               indirectBufferOffset: ParticleGPUSystem.Control.dispatchOffset,
                                                               threadsPerThreadgroup: group) }
        let isEventChild = system.configuration.link?.kind != .static
        if isEventChild, let flags = gpu.eventFlags, let offsets = gpu.eventOffsets, let blockSums = gpu.eventBlockSums,
           let events = gpu.events {
            encoder.setComputePipelineState(eventMark)
            encoder.setBuffer(parentStepped, offset: 0, index: 0)
            encoder.setBuffer(parentAlive, offset: 0, index: 1)
            encoder.setBuffer(parent.control, offset: 0, index: 2)
            encoder.setBuffer(flags, offset: 0, index: 3)
            encoder.setBuffer(gpu.parameters, offset: 0, index: 4)
            perParentParticle()
            scan(flags, count: ParticleGPUSystem.Control.total, into: ParticleGPUSystem.Control.eventTotal,
                 offsets: offsets, blockSums: blockSums, control: parent.control, totals: gpu.control, encoder: encoder)
            encoder.setComputePipelineState(eventScatter)
            encoder.setBuffer(flags, offset: 0, index: 0)
            encoder.setBuffer(offsets, offset: 0, index: 1)
            encoder.setBuffer(blockSums, offset: 0, index: 2)
            encoder.setBuffer(parent.control, offset: 0, index: 3)
            encoder.setBuffer(events, offset: 0, index: 4)
            perParentParticle()
        }
        encoder.setComputePipelineState(instanceStep)
        encoder.setBuffer(gpu.control, offset: 0, index: 0)
        encoder.setBuffer(instances, offset: 0, index: 1)
        encoder.setBuffer(gpu.parameters, offset: 0, index: 2)
        encoder.setBytes(&frame, length: MemoryLayout<ParticleGPUFrame>.stride, index: 3)
        encoder.setBuffer(parentStepped, offset: 0, index: 4)
        encoder.setBuffer(parentParticles, offset: 0, index: 5)
        encoder.setBuffer(parent.control, offset: 0, index: 6)
        encoder.setBuffer(gpu.events ?? gpu.control, offset: 0, index: 7)
        encoder.setBuffer(parent.instances ?? gpu.control, offset: 0, index: 8)
        let single = MTLSize(width: 1, height: 1, depth: 1)
        encoder.dispatchThreads(single, threadsPerThreadgroup: single)
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
