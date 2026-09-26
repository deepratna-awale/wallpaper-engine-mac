/// WE's pre-simulation of a system's `starttime` (`wallpaper64.exe` 0x14022f2e0): before its first
/// frame the system steps 0.05 s at a time (0.2 s for a system of 500 particles or more) until that
/// many seconds have passed.
enum ParticlePrewarm {
    /// The steps to take before `system`'s first frame; none after it.
    static func steps(_ system: ParticleSystemRuntime) -> [Float] {
        guard system.frameIndex == 0 else { return [] }
        return steps(startTime: system.configuration.startTime, maximum: system.configuration.maximumParticleCount)
    }

    static func steps(startTime: Float, maximum: Int) -> [Float] {
        guard startTime > 0, startTime.isFinite else { return [] }
        let step: Float = maximum >= 500 ? 0.2 : 0.05
        let count = Int((startTime / step).rounded(.up))
        return Array(repeating: step, count: min(count, 10_000))
    }
}
