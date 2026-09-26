import Foundation

/// Every property timeline of one wallpaper instance, keyed by site (owner and property key), with
/// WE's per-frame evaluation (docs/timeline-plan.md §2.1, `0x140172370`…`0x1401726f3`):
///
/// 1. For each animation in registration order, its clock owner is its parent, else itself (one
///    level: a parent's own parent doesn't matter to the child).
/// 2. The owner's clock advances once per frame, by `delta × owner.rate` (the rate is 1 until a
///    script writes it); the events it crosses fire, as the owner's.
/// 3. The animation samples **its own** channels on the owner's clock, every frame, paused or not.
///
/// Script calls (`IAnimation`) act on the named animation's own clock and rate, so on a linked
/// child they change nothing visible, as in WE. Texture animations live in `textures`.
///
/// Two displays of one wallpaper each own a set. Confined to the thread that drives the instance's
/// frames (not shared, not locked).
final class SceneAnimationSet {
    private struct Entry {
        let site: SceneAnimationSite
        var timeline: SceneTimelineAnimation
        /// The index of the animation whose clock this one samples (`options.parent`), if linked.
        var parent: Int?
        /// The script wrapper's `rate` (`+0xf8` → `+0xd0`).
        var rate: Float = 1
        /// The frame counter of this clock's last advance: a clock moves at most once per frame.
        var advanced: UInt64 = 0
        /// The last value sampled (`advance(by:)` or `refresh()`).
        var value: [Float] = []
    }

    private let wallpaperID: String
    private var entries: [Entry] = []
    private var indices: [SceneAnimationSite: Int] = [:]
    /// Counts `advance(by:)` calls: WE's engine frame counter (`[engine+0x144]`).
    private(set) var frameCounter: UInt64 = 0
    /// The texture clocks and layer overrides of the same instance.
    let textures = SceneTextureAnimations()

    init(wallpaperID: String) {
        self.wallpaperID = wallpaperID
    }

    /// Every animated property of `document` (`scene.json`), linked and sampled at time 0.
    convenience init(document: SceneJSON, wallpaperID: String) {
        self.init(wallpaperID: wallpaperID)
        SceneAnimationHolders.holders(in: document).forEach { add($0) }
        relink()
        refresh()
    }

    // MARK: - Building

    /// Adds the animated properties of a layer that arrived after load (`createLayer`, an asset's
    /// objects), linked within their owners and sampled at time 0.
    func addObject(_ fields: [String: SceneJSON], id: Int) {
        SceneAnimationHolders.holders(ofObject: fields, id: id).forEach { add($0) }
        relink()
        refresh()
    }

    /// Removes every animation of layer `id` (its fields, overrides, effects and materials) and its
    /// texture animation. A link to a removed parent is cleared (`0x1401774b4`).
    func removeObject(_ id: Int) {
        textures.removeObject(id)
        guard entries.contains(where: { $0.site.owner.objectID == id }) else { return }
        entries.removeAll { $0.site.owner.objectID == id }
        indices = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.site, $0.offset) })
        relink()
    }

    /// Builds a site's timeline from its bound value. A malformed `animation` is logged and left
    /// out: the property keeps its other sources.
    private func add(_ holder: SceneAnimationHolders.Holder) {
        guard let json = holder.fields["animation"] else { return }
        guard indices[holder.site] == nil else {
            OWELog.error(.scene, "\(wallpaperID): \(holder.site) is animated twice; keeping the first")
            return
        }
        do {
            let timeline = try SceneTimelineAnimation(json: json, staticValue: holder.fields["value"])
            indices[holder.site] = entries.count
            entries.append(Entry(site: holder.site, timeline: timeline))
        } catch {
            OWELog.error(.scene, "\(wallpaperID): the animation of \(holder.site) is not used: \(error)")
        }
    }

    /// WE's link (`0x1401769dd`…`0x140176a51`): the parent is the animation of the same owner whose
    /// property key is the child's `parent.key`.
    private func relink() {
        for index in entries.indices {
            let child = entries[index]
            entries[index].parent = child.timeline.parentKey.flatMap {
                indices[SceneAnimationSite(owner: child.site.owner, key: $0)]
            }
            if let key = child.timeline.parentKey, entries[index].parent == nil {
                OWELog.debug(.scene, "\(wallpaperID): \(child.site) follows '\(key)', which isn't animated here")
            }
        }
    }

    // MARK: - Frame

    /// One frame (plan P1: after media, before timers and `update`): advances every clock owner
    /// once by `delta × rate`, samples every site on its owner's clock and returns the values and
    /// the events crossed. `delta` is the frame's scene delta (`SceneClock`), in seconds.
    @discardableResult
    func advance(by delta: Float) -> SceneAnimationFrame {
        frameCounter &+= 1
        var frame = SceneAnimationFrame()
        frame.values.reserveCapacity(entries.count)
        for index in entries.indices {
            let owner = entries[index].parent ?? index
            if entries[owner].advanced != frameCounter {
                entries[owner].advanced = frameCounter
                let step = delta * entries[owner].rate
                let site = entries[owner].site
                for event in entries[owner].timeline.clock.advance(by: step) {
                    frame.events.append(SceneAnimationEvent(site: site, name: event.name, frame: event.frame))
                }
            }
            sample(index)
            frame.values[entries[index].site] = entries[index].value
        }
        return frame
    }

    /// Samples every site again without moving any clock (after script calls, or at load).
    func refresh() {
        entries.indices.forEach(sample)
    }

    private func sample(_ index: Int) {
        let clock = entries[entries[index].parent ?? index].timeline.clock
        entries[index].value = entries[index].timeline.value(on: clock)
    }

    // MARK: - Reads

    /// Every animated site, in registration (evaluation) order.
    var sites: [SceneAnimationSite] { entries.map(\.site) }

    func contains(_ site: SceneAnimationSite) -> Bool { indices[site] != nil }

    /// The site's value as last sampled: one component per channel.
    func value(of site: SceneAnimationSite) -> [Float]? {
        indices[site].map { entries[$0].value }
    }

    /// The site's clock owner: its parent when linked, else itself.
    func clockOwner(of site: SceneAnimationSite) -> SceneAnimationSite? {
        indices[site].map { entries[entries[$0].parent ?? $0].site }
    }

    /// The `IAnimation` state of the site's own animation.
    func state(of site: SceneAnimationSite) -> SceneAnimationState? {
        guard let index = indices[site] else { return nil }
        let entry = entries[index]
        let clock = entry.timeline.clock
        return SceneAnimationState(name: entry.timeline.name, fps: clock.fps, frameCount: clock.length,
                                   duration: clock.duration, rate: entry.rate, time: clock.time,
                                   flags: clock.flags, frame: clock.frame)
    }

    /// `getAnimation(name)`: the first animation of `owner` whose `options.name` is `name`; with no
    /// owner (`thisScene.getAnimation`), the first of any owner, in registration order.
    func site(named name: String, owner: SceneAnimationOwner? = nil) -> SceneAnimationSite? {
        entries.first { $0.timeline.name == name && (owner == nil || $0.site.owner == owner) }?.site
    }

    // MARK: - Script control

    /// Applies an `IAnimation` call to the site's own clock. False when the site isn't animated.
    @discardableResult
    func perform(_ control: SceneAnimationControl, on site: SceneAnimationSite) -> Bool {
        guard let index = indices[site] else { return false }
        switch control {
        case .play: entries[index].timeline.clock.play()
        case .pause: entries[index].timeline.clock.pause()
        case .stop: entries[index].timeline.clock.stop()
        case .setFrame(let frame): entries[index].timeline.clock.setFrame(frame)
        case .setRate(let rate): entries[index].rate = rate
        }
        return true
    }

    /// Takes the state a script frame left (the JS side applies WE's rules to the animation buffer
    /// in call order; the host reads a dirty slot back afterwards): the clock's time, its run-time
    /// bits (`paused`, `finished`, `reversed`; the mode bits are kept) and the rate.
    @discardableResult
    func restore(_ site: SceneAnimationSite, time: Float, flags: SceneTimelineClock.Flags, rate: Float) -> Bool {
        guard let index = indices[site] else { return false }
        let runtime: SceneTimelineClock.Flags = [.paused, .finished, .reversed]
        entries[index].timeline.clock.time = time
        entries[index].timeline.clock.flags = entries[index].timeline.clock.flags.subtracting(runtime)
            .union(flags.intersection(runtime))
        entries[index].rate = rate
        return true
    }

    // MARK: - Textures

    /// The sprite frame layer `id` draws this frame: its texture's shared clock (once per
    /// `advance(by:)`) or the script's override. `delta` is the engine frame time.
    func drawnTextureFrame(object id: Int, delta: Float) -> Int32? {
        textures.drawnFrame(object: id, tick: frameCounter, delta: delta)
    }
}
