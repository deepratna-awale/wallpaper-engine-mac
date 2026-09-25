import Foundation

/// Something that happened outside the render thread and reaches scripts at the start of the next
/// frame, in arrival order (docs/scenescript-plan.md §4.4 step 2).
struct SceneScriptEvent {
    /// Event kinds. The runtime handles the three below; other packages add kinds in their own files
    /// (`extension SceneScriptEvent.Kind { static let mediaPlayback = … }`) and register a JS handler
    /// for them with `__rt.addEventHandler(kind, handler)`.
    struct Kind: RawRepresentable, Hashable {
        let rawValue: String
        init(rawValue: String) { self.rawValue = rawValue }

        /// `applyUserProperties(changed)` on every script; payload: only the changed properties.
        static let userProperties = Kind(rawValue: "userProperties")
        /// `applyGeneralSettings(changed)`; payload: only the changed settings (`language`).
        static let generalSettings = Kind(rawValue: "generalSettings")
        /// `resizeScreen(size)`; payload: `["x": width, "y": height]` in pixels. Never sent at startup.
        static let resize = Kind(rawValue: "resize")
    }

    var kind: Kind
    /// A JavaScript-convertible value: dictionaries, arrays, strings, numbers, booleans, NSNull.
    var payload: Any
    /// The object slot the event is for (cursor events), or nil for every script.
    var target: Int?

    init(kind: Kind, payload: Any, target: Int? = nil) {
        self.kind = kind
        self.payload = payload
        self.target = target
    }

    /// The object `__rt.frame` receives.
    var javaScriptObject: [String: Any] {
        var object: [String: Any] = ["kind": kind.rawValue, "payload": payload]
        if let target { object["target"] = target }
        return object
    }
}
