import Metal

/// One particle system's state on the GPU: its particles, trail history, the scratch the
/// compaction needs, the records it draws from and a small control block of counters and
/// indirect arguments. Buffers grow with the system and are reused every frame.
final class ParticleGPUSystem {
    /// Word indices into `control` (`ParticleSimulation.metal`'s `c…` constants).
    enum Control {
        static let count = 0, emitted = 1, total = 2, serial = 3, remainder = 4, trailTotal = 6
        static let dispatchOffset = 8 * 4
        /// `MTLDrawPrimitivesIndirectArguments` for the material draw and the built-in draw.
        static let materialDrawOffset = 12 * 4
        static let fallbackDrawOffset = 16 * 4
        static let words = 20
    }

    let parameters: MTLBuffer
    /// Counters and indirect arguments; shared so tests and metrics can read the count.
    let control: MTLBuffer
    let historyLimit: Int
    let tracksHistory: Bool
    let maximumCount: Int

    private let device: MTLDevice
    private(set) var capacity = 0
    private(set) var particles: MTLBuffer?
    private(set) var stepped: MTLBuffer?
    private(set) var alive: MTLBuffer?
    private(set) var offsets: MTLBuffer?
    private(set) var blockSums: MTLBuffer?
    private(set) var trailCounts: MTLBuffer?
    /// Ping-ponged by the compaction; `history[historyIndex]` holds the live trails.
    private(set) var history: [MTLBuffer?] = [nil, nil]
    private(set) var historyIndex = 0
    private(set) var records: MTLBuffer?
    private(set) var recordKind: ParticleGPUDrawKind?
    /// Live particles can't exceed this: emission so far, bounded by the maximum. The CPU tracks
    /// it without reading the GPU, so buffers grow before a step can overflow them.
    private(set) var upperBound = 0
    /// This frame's buffers are in place (`ParticleGPUSimulator.encode`); a system that can't
    /// grow draws nothing.
    var isReady = false
    var reportedFailure = false

    init?(device: MTLDevice, configuration: SceneMetalParticleSystem, seed: UInt32) {
        var values = ParticleGPUParameters(configuration, seed: seed)
        guard let parameters = device.makeBuffer(bytes: &values, length: MemoryLayout<ParticleGPUParameters>.stride,
                                                 options: .storageModeShared),
              let control = device.makeBuffer(length: Control.words * 4, options: .storageModeShared) else { return nil }
        memset(control.contents(), 0, control.length)
        self.device = device
        self.parameters = parameters
        self.control = control
        historyLimit = values.historyLimit
        tracksHistory = configuration.rendererName == "ropetrail"
        maximumCount = max(configuration.maximumParticleCount, 0)
        parameters.label = "Particle parameters"
        control.label = "Particle control"
    }

    /// Live particles as of the last completed frame (it may lag the GPU by a frame or two).
    var completedCount: Int {
        Int(control.contents().load(fromByteOffset: Control.count * 4, as: UInt32.self))
    }

    func toggleHistory() { historyIndex ^= 1 }

    /// Updates the bound for this step and grows the state buffers to hold it, copying the live
    /// particles with `blit` (made on demand). False when a buffer can't be allocated.
    func reserve(for inputs: ParticleFrameInputs, blit: () -> MTLBlitCommandEncoder?) -> Bool {
        if inputs.clears {
            upperBound = 0
        } else {
            // The carried remainder is below 1 at the start of a step, so a step spawns at most
            // ⌊rate·Δt⌋ + 1 particles.
            let spawns = Double(max(inputs.emissionRate, 0)) * Double(inputs.deltaTime)
            let bound = Double(upperBound) + spawns.rounded(.down) + 1
            upperBound = Int(min(bound, Double(maximumCount)))
        }
        guard upperBound > capacity || particles == nil else { return true }
        let grown = max(upperBound, capacity * 2, 256)
        let newCapacity = maximumCount > 0 ? min(grown, max(maximumCount, 1)) : 256
        return grow(to: newCapacity, blit: blit)
    }

    private func grow(to newCapacity: Int, blit: () -> MTLBlitCommandEncoder?) -> Bool {
        let stateStride = MemoryLayout<ParticleGPUState>.stride
        let slots = (newCapacity + 255) / 256 * 256
        func buffer(_ bytes: Int, _ label: String) -> MTLBuffer? {
            let buffer = device.makeBuffer(length: max(bytes, 16), options: .storageModePrivate)
            buffer?.label = label
            return buffer
        }
        guard let newParticles = buffer(slots * stateStride, "Particles"),
              let newStepped = buffer(slots * stateStride, "Particles stepped"),
              let newAlive = buffer(slots * 4, "Particle alive"),
              let newOffsets = buffer(slots * 4, "Particle offsets"),
              let newBlockSums = buffer((slots / 256 + 1) * 4, "Particle block sums") else { return false }
        var newHistory: [MTLBuffer?] = [nil, nil]
        var newTrailCounts: MTLBuffer?
        if tracksHistory {
            let bytes = slots * historyLimit * MemoryLayout<SIMD2<Float>>.stride
            guard let first = buffer(bytes, "Particle history"), let second = buffer(bytes, "Particle history"),
                  let counts = buffer(slots * 4, "Particle trail counts") else { return false }
            newHistory = [first, second]
            newTrailCounts = counts
        }
        if let old = particles, capacity > 0, let encoder = blit() {
            encoder.copy(from: old, sourceOffset: 0, to: newParticles, destinationOffset: 0,
                         size: min(old.length, newParticles.length))
            if let oldHistory = history[historyIndex], let target = newHistory[historyIndex] {
                encoder.copy(from: oldHistory, sourceOffset: 0, to: target, destinationOffset: 0,
                             size: min(oldHistory.length, target.length))
            }
        }
        particles = newParticles
        stepped = newStepped
        alive = newAlive
        offsets = newOffsets
        blockSums = newBlockSums
        history = newHistory
        trailCounts = newTrailCounts
        capacity = newCapacity
        records = nil
        return true
    }

    /// The record buffer for `kind`, large enough for the current capacity.
    func recordBuffer(for kind: ParticleGPUDrawKind, subdivision: Int) -> MTLBuffer? {
        let bytes = Self.recordBytes(kind, capacity: capacity, historyLimit: historyLimit, subdivision: subdivision)
        if let records, recordKind == kind, records.length >= bytes { return records }
        records = device.makeBuffer(length: max(bytes, 16), options: .storageModePrivate)
        records?.label = "Particle records"
        recordKind = kind
        return records
    }

    static func recordBytes(_ kind: ParticleGPUDrawKind, capacity: Int, historyLimit: Int, subdivision: Int) -> Int {
        let instance = MemoryLayout<LayerUniform>.stride
        switch kind {
        case .sprite: return capacity * MemoryLayout<ParticleSpriteInstance>.stride
        case .rope: return capacity * MemoryLayout<ParticleRopeSegmentInstance>.stride
        case .ropeTrail: return capacity * historyLimit * MemoryLayout<ParticleRopeSegmentInstance>.stride
        case .fallbackSprite, .fallbackSpriteTrail: return capacity * instance
        case .fallbackRope: return capacity * subdivision * instance
        case .fallbackRopeTrail: return capacity * historyLimit * subdivision * instance
        }
    }
}
