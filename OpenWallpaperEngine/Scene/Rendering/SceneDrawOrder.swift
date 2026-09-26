/// How WE's object loop orders a scene's objects (0x14018aac0; docs/models-plan.md §2.4). The
/// renderer draws scene.json order today, which is `.sceneOrder`'s; M4 applies the other modes.
struct SceneDrawOrderMode: Equatable {
    /// `customsortorder` without `transparentsorting` (flags & 0x3000 == 0x2000): a stable sort
    /// by each object's `sortorder`, ascending (comparator 0x140186980).
    var sortsBySortOrder = false
    /// `transparentsorting` in a perspective scene (flags & 0x1008 == 0x1000): every object not
    /// flagged translucent first, in list order, then the translucent ones back to front by
    /// `dot(origin, camera forward)`, descending (0x1401865c0).
    var splitsTranslucent = false

    /// Plain scene.json order: every orthographic scene without `customsortorder`, and the default.
    static let sceneOrder = SceneDrawOrderMode()

    init(sortsBySortOrder: Bool = false, splitsTranslucent: Bool = false) {
        self.sortsBySortOrder = sortsBySortOrder
        self.splitsTranslucent = splitsTranslucent
    }

    /// The flag tests of the object loop. Both flags set sort nothing: `customsortorder` needs
    /// `transparentsorting` off, and `transparentsorting` needs a perspective scene. An
    /// orthographic scene with camera parallax walks the same (possibly sorted) list with a
    /// per-object offset (0x14018ac84), which doesn't change the order.
    init(_ settings: SceneCameraSettings) {
        sortsBySortOrder = settings.customSortOrder && !settings.transparentSorting
        splitsTranslucent = settings.transparentSorting && settings.projection.isPerspective
    }
}
