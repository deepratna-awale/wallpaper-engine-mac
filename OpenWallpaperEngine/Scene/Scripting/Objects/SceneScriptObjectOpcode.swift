import Foundation

/// The object model's command-ring opcodes (400–999). `objects-values.js` mirrors the numbers in
/// `__rt.objects.OP`; `SceneScriptObjectModel` decodes them into `SceneScriptObjectCommand`s.
extension SceneScriptCommandRing.Opcode {
    /// target slot. The source is kept natively from the synchronous describe.
    static let objectCreate = Self(rawValue: 400)
    /// target slot.
    static let objectDestroy = Self(rawValue: 401)
    /// target slot; numbers [index].
    static let objectSort = Self(rawValue: 402)
    /// target slot; strings [field, value].
    static let objectSetString = Self(rawValue: 403)
    /// target slot; numbers [effect, material or -1, components…]; strings [name].
    static let materialSetProperty = Self(rawValue: 410)
    /// target slot; numbers [effect]; strings [name].
    static let materialExecuteFunction = Self(rawValue: 411)
    /// target slot.
    static let soundPlay = Self(rawValue: 420)
    static let soundPause = Self(rawValue: 421)
    static let soundStop = Self(rawValue: 422)
    /// target slot.
    static let particlesPlay = Self(rawValue: 430)
    static let particlesPause = Self(rawValue: 431)
    static let particlesStop = Self(rawValue: 432)
    /// target slot; numbers [] or [count].
    static let particlesEmit = Self(rawValue: 433)
    /// target animation slot.
    static let animationPlay = Self(rawValue: 440)
    static let animationPause = Self(rawValue: 441)
    static let animationStop = Self(rawValue: 442)
    /// target animation slot; numbers [frame].
    static let animationSetFrame = Self(rawValue: 443)
    static let animationJoin = Self(rawValue: 444)

    /// Every object-model opcode with its JS name, for `__rt.objects.OP`.
    static let objectModelOpcodes: [String: Self] = [
        "create": .objectCreate, "destroy": .objectDestroy, "sort": .objectSort, "setString": .objectSetString,
        "setMaterialProperty": .materialSetProperty, "executeMaterialFunction": .materialExecuteFunction,
        "soundPlay": .soundPlay, "soundPause": .soundPause, "soundStop": .soundStop,
        "particlesPlay": .particlesPlay, "particlesPause": .particlesPause, "particlesStop": .particlesStop,
        "particlesEmit": .particlesEmit, "animationPlay": .animationPlay, "animationPause": .animationPause,
        "animationStop": .animationStop, "animationSetFrame": .animationSetFrame, "animationJoin": .animationJoin,
    ]
}
