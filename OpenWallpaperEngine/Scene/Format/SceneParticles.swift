import Foundation

struct WEParticleSystem: Codable {
    var emitter: [WEParticleEmitter]?
    var initializer: [WEParticleInitializer]?
    var `operator`: [WEParticleOperator]?
    var renderer: [WEParticleRenderer]?
    var material: String?
    @WEFlexibleInt var maxcount: Int?
    @WEFlexibleInt var flags: Int?
    @WEFlexibleDouble var starttime: Double?
    var animationmode: String?
    @WEFlexibleDouble var sequencemultiplier: Double?
    var controlpoint: [WEParticleControlPoint]?
    /// Child systems (`WEParticleChild`): static ones placed on this system, event ones spawned
    /// for its particles.
    var children: [WEParticleChild]?

    /// `flags` bit 0: particles ignore the system's transform once spawned (`worldspace`).
    var isWorldSpace: Bool { ((flags ?? 0) & 1) != 0 }
}

/// An entry of a particle system's `children`.
struct WEParticleChild: Codable {
    /// Path of the child's particle json.
    var name: String?
    /// `static` (the default), `eventfollow`, `eventspawn` or `eventdeath`.
    var type: String?
    var origin: WEFlexValue?
    var scale: WEFlexValue?
    var angles: WEFlexValue?
    /// Chance an event creates an instance of the child (default 1).
    @WEFlexibleDouble var probability: Double?
    /// Event children: how many instances of the child may exist at once (default 10).
    @WEFlexibleInt var maxcount: Int?
    /// Bit 0: the child's control points from `controlpointstartindex` on are this system's particles.
    @WEFlexibleInt var flags: Int?
    @WEFlexibleInt var controlpointstartindex: Int?
    @WEFlexibleInt var id: Int?
}

struct WEParticleEmitter: Codable {
    @WEFlexibleInt var id: Int?
    var name: String?
    @WEFlexibleDouble var rate: Double?
    var origin: String?
    var distancemax: WEFlexValue?
    var distancemin: WEFlexValue?
    @WEFlexibleDouble var speedmax: Double?
    @WEFlexibleDouble var speedmin: Double?
    @WEFlexibleInt var controlpoint: Int?
    /// Particles emitted at once when the emitter starts.
    @WEFlexibleInt var instantaneous: Int?
    /// Per-axis scale of the spawn shape ("1 1 0" by default).
    var directions: WEFlexValue?
    /// Per-axis sign the spawn offset is forced to (0 keeps both).
    var sign: WEFlexValue?
}

struct WEParticleControlPoint: Codable {
    @WEFlexibleInt var id: Int?
    @WEFlexibleInt var flags: Int?
    var offset: String?
    var locktopointer: Bool?
    @WEFlexibleInt var parentcontrolpoint: Int?
}

struct WEParticleInitializer: Codable {
    @WEFlexibleInt var id: Int?
    var name: String?
    var min: WEFlexValue?
    var max: WEFlexValue?
    @WEFlexibleInt var flags: Int?
    @WEFlexibleDouble var count: Double?
    @WEFlexibleDouble var arcamount: Double?
    var limitbehavior: String?
    var axis: String?
    var bounds: String?
    @WEFlexibleInt var controlpoint0: Int?
    @WEFlexibleInt var controlpoint1: Int?
    var speedmin: WEFlexValue?
    var speedmax: WEFlexValue?
    var input: String?
    var output: String?
    var operation: String?
    @WEFlexibleInt var inputcontrolpoint0: Int?
    @WEFlexibleDouble var inputrangemin: Double?
    @WEFlexibleDouble var inputrangemax: Double?
}

struct WEParticleOperator: Codable {
    @WEFlexibleInt var id: Int?
    var name: String?
    var gravity: String?
    @WEFlexibleDouble var drag: Double?
    @WEFlexibleDouble var fadeintime: Double?
    @WEFlexibleDouble var fadeouttime: Double?
    var scale: WEFlexValue?
    @WEFlexibleDouble var speedmin: Double?
    @WEFlexibleDouble var speedmax: Double?
    @WEFlexibleDouble var timescale: Double?
    var mask: WEFlexValue?
    @WEFlexibleDouble var phasemin: Double?
    @WEFlexibleDouble var phasemax: Double?
    @WEFlexibleInt var controlpoint: Int?
    var origin: WEFlexValue?
    @WEFlexibleDouble var threshold: Double?
    @WEFlexibleDouble var starttime: Double?
    @WEFlexibleDouble var endtime: Double?
    var startvalue: WEFlexValue?
    var endvalue: WEFlexValue?
    var force: String?
    var axis: String?
    @WEFlexibleDouble var distanceinner: Double?
    @WEFlexibleDouble var distanceouter: Double?
    @WEFlexibleDouble var speedinner: Double?
    @WEFlexibleDouble var speedouter: Double?
    @WEFlexibleDouble var maxspeed: Double?
    @WEFlexibleDouble var ringradius: Double?
    @WEFlexibleDouble var ringwidth: Double?
    @WEFlexibleDouble var ringpulldistance: Double?
    @WEFlexibleDouble var alignmentfactor: Double?
    @WEFlexibleDouble var cohesionfactor: Double?
    @WEFlexibleDouble var separationfactor: Double?
    @WEFlexibleDouble var neighborthreshold: Double?
    @WEFlexibleDouble var frequencymin: Double?
    @WEFlexibleDouble var frequencymax: Double?
    @WEFlexibleDouble var scalemin: Double?
    @WEFlexibleDouble var scalemax: Double?
    @WEFlexibleDouble var reductioninner: Double?
    @WEFlexibleDouble var variablestrength: Double?
    var input: String?
    var output: String?
    var operation: String?
    var transformfunction: String?
    @WEFlexibleDouble var transforminputscale: Double?
    var outputrangemin: WEFlexValue?
    var outputrangemax: WEFlexValue?
    @WEFlexibleInt var controlpoint0: Int?
    @WEFlexibleInt var controlpoint1: Int?
    /// `movement`: bit 0 applies gravity in world space rather than the system's.
    @WEFlexibleInt var flags: Int?
}

struct WEParticleRenderer: Codable {
    @WEFlexibleInt var id: Int?
    var name: String?       // "sprite", "spritetrail"
    @WEFlexibleDouble var length: Double?
    @WEFlexibleDouble var maxlength: Double?
    @WEFlexibleDouble var minlength: Double?
    @WEFlexibleInt var segments: Int?
    @WEFlexibleInt var subdivision: Int?
    var fadealpha: Bool?
    var fadesize: Bool?
}

// MARK: - String Parsing Helpers
