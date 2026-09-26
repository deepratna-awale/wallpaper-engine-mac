import simd

/// What a child particle takes from the parent particle of its instance's event:
/// `inheritinitialvaluefromevent` once when it spawns, `inheritvaluefromevent` every step.
/// Each case is one of WE's `input` verbs; `ParticleSimulation.metal` applies the same bits in the
/// same order.
struct ParticleInheritance: OptionSet, Hashable {
    let rawValue: UInt32

    static let setColor = ParticleInheritance(rawValue: 1 << 0)
    static let multiplyColor = ParticleInheritance(rawValue: 1 << 1)
    static let setOpacity = ParticleInheritance(rawValue: 1 << 2)
    static let multiplyOpacity = ParticleInheritance(rawValue: 1 << 3)
    static let setVelocity = ParticleInheritance(rawValue: 1 << 4)
    static let addVelocity = ParticleInheritance(rawValue: 1 << 5)
    static let setSize = ParticleInheritance(rawValue: 1 << 6)
    static let multiplySize = ParticleInheritance(rawValue: 1 << 7)
    static let setRotation = ParticleInheritance(rawValue: 1 << 8)
    static let addRotation = ParticleInheritance(rawValue: 1 << 9)
    static let setAngularVelocity = ParticleInheritance(rawValue: 1 << 10)
    static let addAngularVelocity = ParticleInheritance(rawValue: 1 << 11)

    /// The verbs every step can apply: adding the source's velocity or rotation every step would
    /// compound, so those are spawn-only.
    static let eachStep: ParticleInheritance = [.setColor, .multiplyColor, .setOpacity, .multiplyOpacity,
                                                .setVelocity, .setSize, .multiplySize, .setRotation,
                                                .setAngularVelocity]

    /// An `input` verb; nil for one WE doesn't have.
    init?(input: String) {
        switch input.lowercased() {
        case "setcolor": self = .setColor
        case "multiplycolor": self = .multiplyColor
        case "setopacity": self = .setOpacity
        case "multiplyopacity": self = .multiplyOpacity
        case "setcoloropacity": self = [.setColor, .setOpacity]
        case "multiplycoloropacity": self = [.multiplyColor, .multiplyOpacity]
        case "setvelocity": self = .setVelocity
        case "addvelocity": self = .addVelocity
        case "setsize": self = .setSize
        case "multiplysize": self = .multiplySize
        case "setrotation": self = .setRotation
        case "addrotation": self = .addRotation
        case "setangularvelocity": self = .setAngularVelocity
        case "addangularvelocity": self = .addAngularVelocity
        default: return nil
        }
    }

    init(rawValue: UInt32) { self.rawValue = rawValue }

    /// Applies the verbs to a spawning particle (its base values too).
    func applyOnSpawn(to particle: inout Particle, from source: ParticleInstance) {
        let rgb = SIMD3(source.sourceColor.x, source.sourceColor.y, source.sourceColor.z)
        if contains(.setColor) { particle.setColor(rgb) }
        if contains(.multiplyColor) { particle.setColor(particle.rgb * rgb) }
        if contains(.setOpacity) { particle.setAlpha(source.sourceColor.w) }
        if contains(.multiplyOpacity) { particle.setAlpha(particle.alpha * source.sourceColor.w) }
        if contains(.setVelocity) { particle.velocity = source.sourceVelocity }
        if contains(.addVelocity) { particle.velocity += source.sourceVelocity }
        if contains(.setSize) { particle.setSize(source.sourceSize) }
        if contains(.multiplySize) { particle.setSize(particle.size * source.sourceSize) }
        if contains(.setRotation) { particle.rotation = source.sourceRotation }
        if contains(.addRotation) { particle.rotation += source.sourceRotation }
        if contains(.setAngularVelocity) { particle.angularVelocity = source.sourceAngularVelocity }
        if contains(.addAngularVelocity) { particle.angularVelocity += source.sourceAngularVelocity }
    }

    /// Applies the verbs after a step's operators: multiplying works from the particle's base
    /// value, so it doesn't compound.
    func applyEachStep(to particle: inout Particle, from source: ParticleInstance) {
        let rgb = SIMD3(source.sourceColor.x, source.sourceColor.y, source.sourceColor.z)
        let baseRGB = SIMD3(particle.baseColor.x, particle.baseColor.y, particle.baseColor.z)
        if contains(.setColor) { particle.color = SIMD4(rgb, particle.color.w) }
        if contains(.multiplyColor) { particle.color = SIMD4(baseRGB * rgb, particle.color.w) }
        if contains(.setOpacity) { particle.alpha = source.sourceColor.w }
        if contains(.multiplyOpacity) { particle.alpha = particle.baseAlpha * source.sourceColor.w }
        if contains(.setVelocity) { particle.velocity = source.sourceVelocity }
        if contains(.setSize) { particle.size = source.sourceSize }
        if contains(.multiplySize) { particle.size = particle.baseSize * source.sourceSize }
        if contains(.setRotation) { particle.rotation = source.sourceRotation }
        if contains(.setAngularVelocity) { particle.angularVelocity = source.sourceAngularVelocity }
    }
}

private extension Particle {
    var rgb: SIMD3<Float> { SIMD3(color.x, color.y, color.z) }

    mutating func setColor(_ rgb: SIMD3<Float>) {
        color = SIMD4(rgb, color.w)
        baseColor = color
    }

    mutating func setAlpha(_ value: Float) {
        alpha = value
        baseAlpha = value
    }

    mutating func setSize(_ value: Float) {
        size = value
        baseSize = value
    }
}
