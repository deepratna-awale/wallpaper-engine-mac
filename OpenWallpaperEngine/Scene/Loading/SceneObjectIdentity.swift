//
//  SceneObjectIdentity.swift
//  Open Wallpaper Engine
//

/// The id an object is known by when scene.json leaves `id` out. The transform hierarchy keys
/// such objects by their index in `objects`; layers, visibility and property keys use the same
/// id so a parent lookup, a layer and its controls all agree.
enum SceneObjectIdentity {
    static func assigningFallbackIDs(_ objects: [WESceneObject]) -> [WESceneObject] {
        objects.enumerated().map { index, object in
            guard object.id == nil else { return object }
            var keyed = object
            keyed.id = index
            return keyed
        }
    }
}
