import Foundation

/// The scene's own script-visible values (lib.sceneScript.d.ts `IScene` settings and
/// `get/setCameraTransforms`), laid out in the one-slot scene buffer of `SceneScriptObjectModel`.
/// `objects-scene.js` generates `thisScene`'s accessors from this list.
enum SceneScriptSceneField: String, CaseIterable {
    case bloom, bloomstrength, bloomthreshold, clearenabled, clearcolor, ambientcolor, skylightcolor
    case fov, nearz, farz, camerafade
    case camerashake, camerashakespeed, camerashakeamplitude, camerashakeroughness
    case cameraparallax, cameraparallaxamount, cameraparallaxdelay, cameraparallaxmouseinfluence
    /// `CameraTransforms`: not members of `thisScene`, read and written through
    /// `getCameraTransforms()`/`setCameraTransforms()`.
    case cameraEye, cameraCenter, cameraUp, cameraZoom

    enum Layout {
        static let stride = 36  // 35 used
        /// Dirty flags: one for the settings, one for the camera transforms.
        static let settingsDirty = 0
        static let cameraDirty = 1
        static let dirtyCount = 2
    }

    var type: SceneScriptObjectField.ValueType {
        switch self {
        case .bloom, .clearenabled, .camerafade, .camerashake, .cameraparallax: return .bool
        case .clearcolor, .ambientcolor, .skylightcolor, .cameraEye, .cameraCenter, .cameraUp: return .vec3
        default: return .number
        }
    }

    var components: Int { type == .vec3 ? 3 : 1 }

    var offset: Int {
        var offset = 0
        for field in Self.allCases {
            if field == self { return offset }
            offset += field.components
        }
        return offset
    }

    var isCamera: Bool { [.cameraEye, .cameraCenter, .cameraUp, .cameraZoom].contains(self) }

    /// The defaults of scene.json's `general` for a value the scene leaves out, and a camera at the
    /// origin looking down -z.
    var defaultValue: [Float] {
        switch self {
        case .clearcolor, .ambientcolor, .skylightcolor: return [0, 0, 0]
        case .cameraEye: return [0, 0, 1]
        case .cameraCenter: return [0, 0, 0]
        case .cameraUp: return [0, 1, 0]
        case .cameraZoom, .clearenabled: return [1]
        case .fov: return [50]
        case .nearz: return [0.01]
        case .farz: return [10000]
        default: return Array(repeating: 0, count: components)
        }
    }

    /// The list `objects-scene.js` builds accessors from; camera fields are not members.
    static var javaScriptObject: [[String: Any]] {
        allCases.map {
            ["name": $0.rawValue, "offset": $0.offset, "type": $0.type.rawValue, "camera": $0.isCamera]
        }
    }
}
