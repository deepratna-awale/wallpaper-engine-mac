import Foundation
import simd

/// The script thread's view of one wallpaper instance's scene (docs/scenescript-plan.md WP11): it
/// is the `SceneScriptObjectHost` the object model talks to, keeps which object sits in which
/// table slot and the draw order, turns script commands into render state and events, and reads
/// the tables back after each frame. Confined to the script thread; the renderer only ever sees
/// the `SceneScriptFrameState` and events it hands over.
final class SceneScriptSceneMirror: SceneScriptObjectHost {
    private struct Object {
        var id: Int
        var kind: SceneScriptObjectDescription.Kind
        var parentID: Int?
        var disablesPropagation: Bool
        /// Its effects' slots in the effect buffer, in effect order.
        var effectSlots: [Int]
    }

    /// A placed animation, for the per-frame clock.
    private struct Clock {
        var slot: Int
        var fps: Double
        var frameCount: Int
    }

    let describer: SceneScriptSceneDescriber
    private let description: SceneScriptSceneDescription
    private let wallpaperID: String
    /// Authored configurations by object id, for `createLayer(layer)` copies.
    private var configurations: [Int: [String: SceneJSON]] = [:]
    /// Layers `createLayer` described, waiting for their `.create` command.
    private var described: [Int: (description: SceneScriptObjectDescription, json: [String: SceneJSON])] = [:]
    private var nextCreatedID = SceneScriptSceneDescriber.firstCreatedID

    private weak var model: SceneScriptObjectModel?
    private var sync: SceneScriptTableSync?
    private var objects: [Int: Object] = [:]
    private var slotsByID: [Int: Int] = [:]
    /// Every live slot in draw order, bottom first, as `objects-scene.js` keeps `objects.order`.
    private var order: [Int] = []
    private var orderChanged = false
    /// Animation slots a script controls (`play`, `pause`, `stop`, `setFrame`, a `rate` write).
    private var controlled = Set<Int>()
    /// Every placed animation; rebuilt when objects come and go.
    private var clocks: [Clock] = []
    private var clocksValid = false
    /// The image and text layers in draw order, for the cursor pass; rebuilt with the order.
    private var hitTestable: [SceneScriptCursorLayer.TableEntry] = []
    private var hitTestableValid = false
    private var reported = Set<String>()

    private(set) var state = SceneScriptFrameState()
    private(set) var events: [SceneScriptRenderEvent] = []

    init(document: SceneJSON, describer: SceneScriptSceneDescriber, wallpaperID: String) {
        self.describer = describer
        self.wallpaperID = wallpaperID
        description = describer.scene(document)
        for (index, fields) in SceneScriptSceneDescriber.objects(of: document).enumerated() {
            configurations[SceneScriptSceneDescriber.objectID(fields, index: index)] = fields
        }
    }

    /// Once the object model placed the scene: learns every object's slot.
    func attach(to model: SceneScriptObjectModel) {
        self.model = model
        guard let store = model.store else { return }
        let sync = SceneScriptTableSync(store: store)
        self.sync = sync
        for object in description.objects {
            guard let slot = model.slot(forObjectID: object.id) else { continue }
            register(object, slot: slot, disablesPropagation: configurations[object.id].map(Self.disablesPropagation) ?? false)
            order.append(slot)
            sync.place(slot: slot, description: object)
        }
    }

    func slot(forObjectID id: Int) -> Int? { slotsByID[id] }

    private func register(_ object: SceneScriptObjectDescription, slot: Int, disablesPropagation: Bool) {
        objects[slot] = Object(id: object.id, kind: object.kind, parentID: object.parentID,
                               disablesPropagation: disablesPropagation,
                               effectSlots: model?.store?.effectBufferSlots(of: slot) ?? [])
        slotsByID[object.id] = slot
        clocksValid = false
        hitTestableValid = false
    }

    private static func disablesPropagation(_ fields: [String: SceneJSON]) -> Bool {
        if case .bool(let flag)? = fields["disablepropagation"] { return flag }
        return false
    }

    // MARK: - SceneScriptObjectHost

    func sceneScriptScene() -> SceneScriptSceneDescription { description }

    func sceneScriptDescribeLayer(_ source: SceneScriptLayerSource) -> SceneScriptObjectDescription? {
        var copying: [String: SceneJSON]?
        if case .copy(let slot) = source, let id = objects[slot]?.id {
            copying = configurations[id] ?? described[id]?.json
        }
        let id = nextCreatedID
        guard let made = describer.layer(source, id: id, copying: copying) else { return nil }
        nextCreatedID += 1
        described[id] = made
        return made.description
    }

    func sceneScriptPerform(_ command: SceneScriptObjectCommand) {
        switch command {
        case .create(let slot, _):
            guard let id = model?.objectID(forSlot: slot), let made = described.removeValue(forKey: id) else { return }
            register(made.description, slot: slot, disablesPropagation: Self.disablesPropagation(made.json))
            configurations[id] = made.json
            order.append(slot)
            orderChanged = true
            sync?.place(slot: slot, description: made.description)
            events.append(.create(id: id, object: made.json))
        case .destroy(let slot):
            guard let object = objects.removeValue(forKey: slot) else { return }
            slotsByID[object.id] = nil
            configurations[object.id] = nil
            order.removeAll { $0 == slot }
            orderChanged = true
            clocksValid = false
            hitTestableValid = false
            state.objects[object.id] = nil
            events.append(.destroy(id: object.id))
        case .sort(let slot, let index):
            guard let from = order.firstIndex(of: slot) else { return }
            order.remove(at: from)
            order.insert(slot, at: max(0, min(index, order.count)))
            orderChanged = true
            hitTestableValid = false
        case .setString(let slot, let field, let value):
            update(slot) { $0.strings[field] = value }
        case .setMaterialProperty(let slot, let effect, let material, let name, let value):
            update(slot) { object in
                var writes = object.constants[effect] ?? []
                writes.removeAll { $0.material == material && $0.name == name }
                if material == nil { writes.removeAll { $0.name == name } }
                writes.append(SceneScriptConstantWrite(material: material, name: name, value: value))
                object.constants[effect] = writes
                object.effectRevision &+= 1
            }
        case .executeMaterialFunction:
            reportOnce("IEffect.executeMaterialFunction", "material functions are not supported yet")
        case .sound:
            reportOnce("ISoundLayer", "sound layers are not played yet; play/pause/stop only change isPlaying()")
        case .particles(let slot, let playback):
            update(slot) { $0.playback = playback }
        case .emitParticles(let slot, let count):
            guard let id = objects[slot]?.id else { return }
            events.append(.emit(id: id, count: count))
        case .animation(let reference, let action):
            perform(action, on: reference)
        }
    }

    private func perform(_ action: SceneScriptObjectCommand.AnimationAction, on reference: SceneScriptAnimationReference) {
        guard reference.slot != nil, reference.effect == nil else {
            reportOnce("IAnimation.effect", "animations of the scene, effects and materials are not script-controlled yet (WP12)")
            return
        }
        if action == .join {
            controlled.remove(reference.animationSlot)
        } else {
            controlled.insert(reference.animationSlot)
        }
    }

    /// Runs `change` on the render state of the object in `slot`, creating it from the table row.
    private func update(_ slot: Int, _ change: (inout SceneScriptObjectState) -> Void) {
        guard let id = objects[slot]?.id, let store = model?.store else { return }
        var object = state.objects[id] ?? SceneScriptObjectState(values: Self.row(slot, in: store))
        change(&object)
        state.objects[id] = object
    }

    private static func row(_ slot: Int, in store: SceneScriptObjectStore) -> [Float] {
        let base = SceneScriptObjectTable.index(slot: slot, field: 0)
        return (0..<SceneScriptObjectTable.Layout.stride).map { store.table.values[base + $0] }
    }

    private func reportOnce(_ key: String, _ message: String) {
        guard reported.insert(key).inserted else { return }
        OWELog.info(.script, "\(wallpaperID): \(message)")
    }

    // MARK: - Frame

    /// Before a frame: the renderer's values into the table, animation clocks, the cursor.
    func prepare(_ input: SceneScriptFrameInput, cursor: SceneScriptCursorExtension?) {
        guard let sync else { return }
        for (id, feedback) in input.objects {
            guard let slot = slotsByID[id] else { continue }
            sync.write(feedback, slot: slot, owned: state.objects[id]?.owned ?? SceneScriptOwnedFields())
        }
        advanceAnimations(by: input.deltaTime)
        guard let cursor, let table = model?.store?.table else { return }
        if !hitTestableValid {
            hitTestableValid = true
            hitTestable = order.compactMap { slot -> SceneScriptCursorLayer.TableEntry? in
                guard let object = objects[slot], object.kind == .image || object.kind == .text else { return nil }
                return SceneScriptCursorLayer.TableEntry(slot: slot, disablesPropagation: object.disablesPropagation)
            }
        }
        let layers = SceneScriptCursorLayer.layers(in: table, drawOrder: hitTestable) { [objects, slotsByID] slot in
            objects[slot]?.parentID.flatMap { slotsByID[$0] }
        }
        let world = input.cursorScenePosition + input.shakeOffset
        cursor.publish(SceneScriptCursorFrame(cursorWorldPosition: SIMD3(world.x, world.y, 0),
                                              leftButtonDown: input.input.cursorLeftDown,
                                              parallax: input.parallax, layers: layers))
    }

    /// WE runs timeline animations before scripts (§1.9 P1): every playing animation's frame
    /// moves on by its fps and rate, wrapping at its length, so `getFrame()` follows the clock.
    private func advanceAnimations(by deltaTime: Double) {
        guard let store = model?.store, deltaTime > 0 else { return }
        refreshClocks(store)
        let buffer = store.animations
        typealias Layout = SceneScriptObjectStore.AnimationLayout
        for clock in clocks where buffer[clock.slot, Layout.playing] != 0 {
            var frame = Double(buffer[clock.slot, Layout.frame]) + deltaTime * clock.fps * Double(buffer[clock.slot, Layout.rate])
            if clock.frameCount > 0, frame.isFinite {
                frame = frame.truncatingRemainder(dividingBy: Double(clock.frameCount))
                if frame < 0 { frame += Double(clock.frameCount) }
            }
            buffer[clock.slot, Layout.frame] = Float(frame)
        }
    }

    /// After a frame: what scripts wrote, into `state`. Returns the state and the events since
    /// the last call.
    func readBack() -> (state: SceneScriptFrameState, events: [SceneScriptRenderEvent]) {
        if let sync, let store = model?.store {
            for (slot, object) in objects {
                let effects = object.effectSlots.isEmpty ? [:] : sync.readEffects(object.effectSlots)
                guard sync.isDirty(slot) else {
                    if !effects.isEmpty { update(slot) { $0.merge(effects: effects) } }
                    continue
                }
                let current = state.objects[object.id]
                let read = sync.read(slot: slot, owned: current?.owned ?? SceneScriptOwnedFields())
                if current == nil, read.owned.isEmpty, effects.isEmpty { continue }
                var updated = current ?? SceneScriptObjectState(values: read.row)
                updated.owned = read.owned
                updated.values = read.row
                updated.merge(effects: effects)
                state.objects[object.id] = updated
            }
            _ = sync.readScene(into: &state.scene)
            for index in 0..<store.constants.dirty.count { store.constants.dirty[index] = 0 }
            readAnimations(store)
        }
        if orderChanged {
            orderChanged = false
            state.order = order.compactMap { objects[$0]?.id }
        }
        defer { events.removeAll(keepingCapacity: true) }
        return (state, events)
    }

    private func refreshClocks(_ store: SceneScriptObjectStore) {
        guard !clocksValid else { return }
        clocksValid = true
        clocks = store.animationDescriptions.map { Clock(slot: $0.key, fps: $0.value.fps, frameCount: $0.value.frameCount) }
    }

    /// A `rate` write makes an animation script-controlled; controlled ones publish where they stand.
    private func readAnimations(_ store: SceneScriptObjectStore) {
        typealias Layout = SceneScriptObjectStore.AnimationLayout
        let buffer = store.animations
        refreshClocks(store)
        for clock in clocks where buffer.dirty[clock.slot] != 0 {
            buffer.dirty[clock.slot] = 0
            controlled.insert(clock.slot)
        }
        guard !controlled.isEmpty else { return }
        controlled = controlled.filter { store.animationReferences[$0] != nil }
        for slot in controlled {
            guard let reference = store.animationReferences[slot], let objectSlot = reference.slot,
                  reference.effect == nil, let animation = store.animationDescriptions[slot],
                  let key = reference.isTextureAnimation ? "texture" : animation.property else { continue }
            let seconds = animation.fps > 0 ? Double(buffer[slot, Layout.frame]) / animation.fps : 0
            update(objectSlot) { $0.animationTimes[key] = seconds }
        }
    }

    func markHalted() {
        state.halted = true
    }
}

private extension SceneScriptObjectState {
    mutating func merge(effects: [Int: Bool]) {
        guard !effects.isEmpty else { return }
        for (index, visible) in effects { effectVisible[index] = visible }
        effectRevision &+= 1
    }
}
