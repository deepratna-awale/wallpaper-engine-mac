import simd

extension SceneScriptEvent.Kind {
    /// `cursorEnter`, `cursorLeave`, `cursorDown`, `cursorUp` or `cursorClick` of one object:
    /// discrete, never merged.
    static let cursor = Self(rawValue: "cursor")
    /// `cursorMove` of one object: a state, so a stalled inbox keeps the newest per object.
    static let cursorMove = Self(rawValue: "cursorMove")
}

/// One cursor callback for the scripts of one object, as the cursor pass produced it.
struct SceneScriptCursorEvent: Equatable {
    /// WE's cursor callbacks and their indices in scenescript64.dll's callback table (0x1819a3ee0).
    enum Callback: String, CaseIterable {
        case cursorEnter, cursorLeave, cursorMove, cursorClick, cursorDown, cursorUp

        var index: Int {
            switch self {
            case .cursorEnter: return 8
            case .cursorLeave: return 9
            case .cursorMove: return 10
            case .cursorClick: return 11
            case .cursorDown: return 12
            case .cursorUp: return 13
            }
        }
    }

    var callback: Callback
    var slot: Int
    var worldPosition: SIMD3<Float>
    /// x and y from the hit test; z is always 0.
    var localPosition: SIMD3<Float>

    /// The inbox event `sceneScriptCursor.js` turns into WE's `CursorEvent`.
    var inboxEvent: SceneScriptEvent {
        let payload: [String: Any] = [
            "callback": callback.rawValue,
            "worldPosition": [Double(worldPosition.x), Double(worldPosition.y), Double(worldPosition.z)],
            "localPosition": [Double(localPosition.x), Double(localPosition.y), Double(localPosition.z)],
        ]
        let isMove = callback == .cursorMove
        return SceneScriptEvent(kind: isMove ? .cursorMove : .cursor, payload: payload, target: slot,
                                coalescing: isMove ? .latest : .keep)
    }
}
