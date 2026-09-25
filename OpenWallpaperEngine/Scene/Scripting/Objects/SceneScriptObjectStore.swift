import Foundation
import JavaScriptCore

/// The object model's shared memory and its allocation: the object table, effect visibility,
/// the material-constant pool, animation state and the scene buffer. Places descriptions into
/// slots (writing their values) and turns them into the records `objects-scene.js` builds live
/// objects from. Confined to the runtime's thread.
final class SceneScriptObjectStore {
    struct Capacity {
        var objects = 2048
        var effects = 8192
        var constantFloats = 65536
        var animations = 4096

        static let standard = Capacity()
    }

    /// Per-animation floats in `animations`.
    enum AnimationLayout {
        static let rate = 0
        static let frame = 1
        static let playing = 2
        static let stride = 4
    }

    struct PoolRange: Hashable {
        var offset: Int
        var count: Int
    }

    /// What a live object slot holds besides its table row.
    private struct Allocation {
        var effects: [Int] = []
        var constants: [PoolRange] = []
        var animations: [Int] = []
    }

    let table: SceneScriptObjectTable
    /// One float per effect: `visible`.
    let effects: SceneScriptSlotBuffer
    /// Material constants, each 1…4 consecutive floats.
    let constants: SceneScriptSlotBuffer
    let animations: SceneScriptSlotBuffer
    /// One slot of `SceneScriptSceneField`s; dirty[0] settings, dirty[1] camera.
    let scene: SceneScriptSlotBuffer

    private var objectSlots: SceneScriptIndexAllocator
    private var effectSlots: SceneScriptIndexAllocator
    private var animationSlots: SceneScriptIndexAllocator
    private var constantTop = 0
    private var freeConstants: [Int: [Int]] = [:]
    private var allocations: [Int: Allocation] = [:]
    private(set) var animationReferences: [Int: SceneScriptAnimationReference] = [:]

    init?(capacity: Capacity, in context: JSContext) {
        guard let table = SceneScriptObjectTable(capacity: capacity.objects, in: context),
              let effects = SceneScriptSlotBuffer(stride: 1, capacity: capacity.effects, in: context),
              let constants = SceneScriptSlotBuffer(stride: 1, capacity: capacity.constantFloats, dirtyCount: 1, in: context),
              let animations = SceneScriptSlotBuffer(stride: AnimationLayout.stride, capacity: capacity.animations,
                                                     in: context),
              let scene = SceneScriptSlotBuffer(stride: SceneScriptSceneField.Layout.stride, capacity: 1,
                                                dirtyCount: SceneScriptSceneField.Layout.dirtyCount, in: context)
        else { return nil }
        self.table = table
        self.effects = effects
        self.constants = constants
        self.animations = animations
        self.scene = scene
        objectSlots = SceneScriptIndexAllocator(capacity: capacity.objects)
        effectSlots = SceneScriptIndexAllocator(capacity: capacity.effects)
        animationSlots = SceneScriptIndexAllocator(capacity: capacity.animations)
    }

    var liveSlots: Set<Int> { Set(allocations.keys) }

    /// Every buffer scripts can reach, for `SceneScriptRuntime.watch(_:)`.
    var sharedBuffers: [SceneScriptDetachable] {
        table.sharedBuffers + effects.sharedBuffers + constants.sharedBuffers + animations.sharedBuffers
            + scene.sharedBuffers
    }

    func isLive(_ slot: Int) -> Bool { allocations[slot] != nil }

    // MARK: - Scene

    /// Writes the scene settings and places the scene-level animations; returns their records.
    func placeScene(settings: [SceneScriptSceneField: [Float]],
                    animations sceneAnimations: [SceneScriptAnimationDescription]) -> [[String: Any]] {
        for field in SceneScriptSceneField.allCases {
            scene.write(settings[field] ?? field.defaultValue, slot: 0, offset: field.offset)
        }
        var ignored = Allocation()
        return sceneAnimations.compactMap {
            place($0, reference: SceneScriptAnimationReference(slot: nil, effect: nil, material: nil, name: $0.name,
                                                                isTextureAnimation: false, animationSlot: -1),
                  into: &ignored)
        }
    }

    // MARK: - Objects

    /// Allocates a slot for `description`, writes its values and returns its JS record, or nil when
    /// a buffer is full (logged by the caller).
    func place(_ description: SceneScriptObjectDescription) -> [String: Any]? {
        guard let slot = objectSlots.take() else { return nil }
        var allocation = Allocation()
        table.reset(slot: slot, with: description.values)
        let reference = SceneScriptAnimationReference(slot: slot, effect: nil, material: nil, name: "",
                                                      isTextureAnimation: false, animationSlot: -1)
        var effectRecords: [[String: Any]] = []
        for (index, effect) in description.effects.enumerated() {
            guard let record = place(effect, index: index, slot: slot, into: &allocation) else {
                release(allocation)
                objectSlots.give(slot)
                return nil
            }
            effectRecords.append(record)
        }
        var textureAnimation: Any = NSNull()
        if let animation = description.textureAnimation {
            var textureReference = reference
            textureReference.isTextureAnimation = true
            guard let record = place(animation, reference: textureReference, into: &allocation) else {
                release(allocation)
                objectSlots.give(slot)
                return nil
            }
            textureAnimation = record
        }
        let animationRecords = description.animations.compactMap { place($0, reference: reference, into: &allocation) }
        allocations[slot] = allocation
        var strings: [String: String] = [:]
        for (field, value) in description.strings where field != .name { strings[field.rawValue] = value }
        return [
            "slot": slot, "kind": description.kind.rawValue, "id": description.id, "name": description.name,
            "parentID": description.parentID.map { $0 as Any } ?? NSNull(), "strings": strings,
            "effects": effectRecords, "textureAnimation": textureAnimation, "animations": animationRecords,
            "config": description.initialConfigurationJSON.map { $0 as Any } ?? NSNull(),
        ]
    }

    /// Frees everything `slot` holds. The JS object was detached when it was destroyed.
    func release(slot: Int) {
        guard let allocation = allocations.removeValue(forKey: slot) else { return }
        release(allocation)
        table.dirty[slot] = 0
        objectSlots.give(slot)
    }

    private func release(_ allocation: Allocation) {
        allocation.effects.forEach { effectSlots.give($0) }
        allocation.animations.forEach {
            animationSlots.give($0)
            animationReferences[$0] = nil
        }
        for range in allocation.constants { freeConstants[range.count, default: []].append(range.offset) }
    }

    private func place(_ effect: SceneScriptObjectDescription.Effect, index: Int, slot: Int,
                       into allocation: inout Allocation) -> [String: Any]? {
        guard let effectSlot = effectSlots.take() else { return nil }
        allocation.effects.append(effectSlot)
        effects[effectSlot, 0] = effect.visible ? 1 : 0
        effects.dirty[effectSlot] = 0
        let reference = SceneScriptAnimationReference(slot: slot, effect: index, material: nil, name: "",
                                                      isTextureAnimation: false, animationSlot: -1)
        var materials: [[String: Any]] = []
        for (materialIndex, material) in effect.materials.enumerated() {
            var constantRecords: [[String: Any]] = []
            for constant in material.constants {
                let count = min(4, max(1, constant.value.count))
                guard let offset = takeConstants(count) else { return nil }
                allocation.constants.append(PoolRange(offset: offset, count: count))
                var value = constant.value
                while value.count < count { value.append(0) }
                constants.write(Array(value.prefix(count)), slot: offset, offset: 0)
                constantRecords.append(["name": constant.name, "offset": offset, "count": count])
            }
            var materialReference = reference
            materialReference.material = materialIndex
            let animations = material.animations.compactMap { place($0, reference: materialReference, into: &allocation) }
            materials.append(["constants": constantRecords, "animations": animations])
        }
        let animations = effect.animations.compactMap { place($0, reference: reference, into: &allocation) }
        return ["index": index, "slot": effectSlot, "name": effect.name, "materials": materials, "animations": animations]
    }

    private func place(_ animation: SceneScriptAnimationDescription, reference: SceneScriptAnimationReference,
                       into allocation: inout Allocation) -> [String: Any]? {
        guard let animationSlot = animationSlots.take() else { return nil }
        allocation.animations.append(animationSlot)
        animations.write([Float(animation.rate), Float(animation.frame), animation.playing ? 1 : 0, 0],
                         slot: animationSlot, offset: 0)
        animations.dirty[animationSlot] = 0
        var placed = reference
        placed.name = animation.name
        placed.animationSlot = animationSlot
        animationReferences[animationSlot] = placed
        return ["slot": animationSlot, "name": animation.name, "fps": animation.fps,
                "frameCount": animation.frameCount, "duration": animation.duration,
                "property": animation.property.map { $0 as Any } ?? NSNull()]
    }

    private func takeConstants(_ count: Int) -> Int? {
        if var free = freeConstants[count], let offset = free.popLast() {
            freeConstants[count] = free
            return offset
        }
        guard constantTop + count <= constants.capacity else { return nil }
        defer { constantTop += count }
        return constantTop
    }
}

/// Hands out the indices 0..<capacity, lowest first, and takes freed ones back.
struct SceneScriptIndexAllocator {
    let capacity: Int
    private var next = 0
    private var free: [Int] = []

    init(capacity: Int) { self.capacity = capacity }

    mutating func take() -> Int? {
        if let index = free.popLast() { return index }
        guard next < capacity else { return nil }
        defer { next += 1 }
        return next
    }

    mutating func give(_ index: Int) { free.append(index) }
}
