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
}

struct WEParticleEmitter: Codable {
    @WEFlexibleInt var id: Int?
    var name: String?
    @WEFlexibleDouble var rate: Double?
    var origin: String?
    var directions: String?
    var distancemax: WEFlexValue?
    var distancemin: WEFlexValue?
    @WEFlexibleDouble var speedmax: Double?
    @WEFlexibleDouble var speedmin: Double?
    @WEFlexibleInt var controlpoint: Int?
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
