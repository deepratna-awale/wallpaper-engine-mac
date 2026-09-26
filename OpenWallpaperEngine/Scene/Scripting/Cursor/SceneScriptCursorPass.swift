import simd

/// WE's per-frame cursor pass (wallpaper64.exe 0x140189e10, the first step of the frame, §1.9 P1):
/// which objects' scripts get which cursor callbacks. One per wallpaper instance; the state is the
/// set of objects under the cursor, the set pressed, and last frame's cursor and button.
///
/// The pass walks the layers from the top of the draw order down, skipping objects that aren't
/// solid, and hit tests each (`SceneScriptCursorHitTest`). For each object, all of its events come before
/// the next object's:
/// - **Dragging** (objects were pressed before this frame and the button is still down): only the
///   pressed objects get `cursorMove`, when the cursor moved, hit or not. No enter, leave or other
///   event reaches any object until the button is released.
/// - **Hit:** `cursorEnter` if it was not under the cursor; `cursorMove` if the cursor moved; when
///   the button changed, `cursorDown` or `cursorUp`, then on a press the object becomes pressed,
///   and on a release a pressed object gets `cursorClick`. A hit on a visible object with
///   `disablepropagation` ends the pass: objects under it are not visited this frame (they keep
///   their state, so no `cursorLeave` either). Otherwise the pass goes on down: overlapping solid
///   objects all get the events.
/// - **Missed:** on a release, a pressed object gets `cursorUp` (no click); an object that was
///   under the cursor gets `cursorLeave`.
///
/// After the pass, a released button clears the pressed set. Objects that are gone from the frame
/// are forgotten (WE drops destroyed objects; a slot may be reused).
struct SceneScriptCursorPass {
    private var hovered: Set<Int> = []
    private var pressed: Set<Int> = []
    private var previousCursor: SIMD2<Float>?
    private var previousLeftButtonDown = false

    /// The objects under the cursor, and those pressed, after the last update.
    var hoveredSlots: Set<Int> { hovered }
    var pressedSlots: Set<Int> { pressed }

    mutating func update(_ frame: SceneScriptCursorFrame) -> [SceneScriptCursorEvent] {
        let present = Set(frame.layers.map(\.slot))
        hovered.formIntersection(present)
        pressed.formIntersection(present)

        let world = frame.cursorWorldPosition
        let cursor = SIMD2(world.x, world.y)
        let moved = previousCursor != cursor
        previousCursor = cursor
        let down = frame.leftButtonDown
        let changed = down != previousLeftButtonDown
        let dragging = !pressed.isEmpty && down

        var events: [SceneScriptCursorEvent] = []
        for layer in frame.layers.reversed() where layer.isSolid {
            let hit = SceneScriptCursorHitTest.test(layer, cursor: cursor, offset: frame.parallaxOffset(of: layer))
            let local = SIMD3(hit.localPosition.x, hit.localPosition.y, 0)
            func emit(_ callback: SceneScriptCursorEvent.Callback) {
                events.append(SceneScriptCursorEvent(callback: callback, slot: layer.slot, worldPosition: world, localPosition: local))
            }
            let wasPressed = pressed.contains(layer.slot)
            if dragging {
                if wasPressed && moved { emit(.cursorMove) }
                continue
            }
            guard hit.isInside else {
                if changed && !down && wasPressed { emit(.cursorUp) }
                if hovered.remove(layer.slot) != nil { emit(.cursorLeave) }
                continue
            }
            if hovered.insert(layer.slot).inserted { emit(.cursorEnter) }
            if moved { emit(.cursorMove) }
            if changed {
                emit(down ? .cursorDown : .cursorUp)
                if down {
                    pressed.insert(layer.slot)
                } else if wasPressed {
                    emit(.cursorClick)
                }
            }
            if layer.stopsPropagation { break }
        }
        previousLeftButtonDown = down
        if !down { pressed.removeAll() }
        return events
    }
}
