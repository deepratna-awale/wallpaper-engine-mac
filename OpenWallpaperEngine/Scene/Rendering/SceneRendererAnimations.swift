import Foundation

/// The renderer's side of a wallpaper instance's timelines and texture clocks
/// (docs/timeline-plan.md §2, T3): the `SceneAnimationSet`, kept across content rebuilt from the
/// same document, and what one frame reads of it (each animated object's fields, each layer's
/// sprite frame, the scripts' states). Confined to the render thread, like the renderer.
final class SceneRendererAnimations {
    /// The instance's timelines and texture clocks, advanced once per frame before the scripts
    /// run; nil without a scene document.
    private(set) var set: SceneAnimationSet?
    /// The document `set` was built from (`SceneTimelineSource`).
    private var key: (wallpaperID: String, signature: String)?
    /// Objects whose own fields a timeline drives (with those fields' keys), and the fields'
    /// values this frame, by id.
    private var animatedObjects: [(id: Int, key: String, fields: Set<String>)] = []
    private var objectAnimations: [String: SceneObjectAnimation] = [:]
    /// Each animated layer's sprite frame this frame, by id (`spriteFrame(object:delta:)`).
    private var spriteFrames: [Int: Int32] = [:]

    /// Drops everything (the content is gone).
    func clear() {
        set = nil
        key = nil
        animatedObjects = []
        objectAnimations = [:]
    }

    /// Takes the content's timelines: a new set for a new document, or when new scripts started
    /// (`restart`: the old ones' created layers and calls are gone); otherwise the running set
    /// keeps its clocks, as WE keeps a scene's across a user property change.
    func setTimelines(_ source: SceneTimelineSource?, restart: Bool) {
        guard let source else {
            set = nil
            key = nil
            refreshAnimatedObjects()
            return
        }
        if restart || set == nil || key?.wallpaperID != source.wallpaperID || key?.signature != source.signature {
            set = SceneAnimationSet(document: source.document, wallpaperID: source.wallpaperID)
            key = (source.wallpaperID, source.signature)
        }
        refreshAnimatedObjects()
    }

    /// A layer `createLayer` made: its timelines join the set.
    func addObject(_ object: [String: SceneJSON], id: Int) {
        set?.addObject(object, id: id)
        refreshAnimatedObjects()
    }

    /// A destroyed layer: its timelines and texture animation leave the set.
    func removeObject(_ id: Int) {
        set?.removeObject(id)
        refreshAnimatedObjects()
    }

    /// What a script frame's `IAnimation` calls left of a timeline's clock.
    func restore(_ site: SceneAnimationSite, time: Float, flags: SceneTimelineClock.Flags, rate: Float) {
        set?.restore(site, time: time, flags: flags, rate: rate)
    }

    /// What a script frame's `ITextureAnimation` calls left of layer `id`'s override.
    func restoreTexture(_ control: SceneTextureAnimationControl, object id: Int) {
        set?.textures.restore(control, object: id)
    }

    /// An animated texture's layer shares its texture's clock (§2.7), frame times in sheet order.
    func registerTexture(object id: Int, texture: String, frameTimes: [Float]) {
        set?.textures.register(object: id, texture: texture, frameTimes: frameTimes)
    }

    /// The objects with an animated field of their own, whose values `advance` reads.
    private func refreshAnimatedObjects() {
        var fields: [Int: Set<String>] = [:]
        for site in set?.sites ?? [] where SceneObjectAnimation.keys.contains(site.key) {
            if case .object(let id) = site.owner { fields[id, default: []].insert(site.key) }
        }
        animatedObjects = fields.keys.sorted().map { ($0, String($0), fields[$0] ?? []) }
        objectAnimations.removeAll()
        guard let set else { return }
        for object in animatedObjects {
            objectAnimations[object.key] = SceneObjectAnimation(set, object: object.id, keys: object.fields)
        }
    }

    // MARK: - Frame

    /// One frame of the instance's timelines (plan P1: before the scripts): every clock owner
    /// advances by the frame's scene delta and every animated field is sampled. Returns the
    /// events crossed, for the scripts.
    func advance(by delta: Float) -> [SceneAnimationEvent] {
        spriteFrames.removeAll(keepingCapacity: true)
        guard let set else { return [] }
        let frame = set.advance(by: delta)
        for object in animatedObjects {
            objectAnimations[object.key] = SceneObjectAnimation(set, object: object.id, keys: object.fields)
        }
        return frame.events
    }

    /// Object `key`'s fields as its timelines set them this frame; nil when none is animated.
    func object(_ key: String) -> SceneObjectAnimation? {
        objectAnimations[key]
    }

    /// The sprite frame layer `id` draws this frame, taken once per frame (a script's override
    /// advances each time it is asked). `delta` is the engine frame time.
    func spriteFrame(object id: Int, delta: Float) -> Int32 {
        if let drawn = spriteFrames[id] { return drawn }
        let frame = set?.drawnTextureFrame(object: id, delta: delta) ?? 0
        spriteFrames[id] = frame
        return frame
    }

    /// The scripts' view of this frame: every timeline's `IAnimation` state, every layer's texture
    /// state and the events the advance crossed.
    func describe(into input: inout SceneScriptFrameInput, events: [SceneAnimationEvent]) {
        guard let set else { return }
        input.animationEvents = events
        for site in set.sites { input.animations[site] = set.state(of: site) }
        for id in set.textures.objectIDs { input.textureAnimations[id] = set.textures.state(object: id) }
    }

    /// Resolves bound values against this frame's timelines.
    var values: LiveSceneValueContext { LiveSceneValueContext(animations: set) }
}
