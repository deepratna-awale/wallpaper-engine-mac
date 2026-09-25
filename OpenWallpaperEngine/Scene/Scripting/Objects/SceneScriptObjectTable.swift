import Foundation
import JavaScriptCore

/// The struct-of-arrays the renderer and scripts share (docs/scenescript-plan.md §4.3): one slot of
/// `Layout.stride` floats per scene object, plus one dirty byte per slot. WP2 fixes the layout;
/// WP7 fills it from the scene and builds the JS layer classes over it (`runtime/layers.js`), and
/// WP11 makes the renderer read it.
///
/// Units are the renderer's: angles in radians (the JS getters convert to WE's degrees), colours
/// 0…1, `visible` 0 or 1. `worldMatrix` is written by the renderer after its transform pass
/// (column-major, like simd), for `getTransformMatrix` and cursor hit tests.
final class SceneScriptObjectTable {
    /// Float offsets within a slot. Effect and material slots are separate tables (WP7).
    enum Layout {
        static let origin = 0          // x y z
        static let angles = 3          // x y z, radians
        static let scale = 6           // x y z
        static let alpha = 9
        static let color = 10          // r g b
        static let visible = 13
        static let parallaxDepth = 14  // x y
        static let size = 16           // x y, read-only for scripts
        static let worldMatrix = 18    // 16 floats
        static let stride = 36         // 34 used, padded to a multiple of 4

        /// The offsets as the JS side reads them (`__rt.table.layout`).
        static var javaScriptObject: [String: Int] {
            ["origin": origin, "angles": angles, "scale": scale, "alpha": alpha, "color": color,
             "visible": visible, "parallaxDepth": parallaxDepth, "size": size,
             "worldMatrix": worldMatrix, "stride": stride]
        }
    }

    let capacity: Int
    let values: SceneScriptSharedBuffer<Float>
    /// 1 when a script wrote the slot this frame; the renderer clears it after reading.
    let dirty: SceneScriptSharedBuffer<UInt8>

    init?(capacity: Int, in context: JSContext) {
        guard let values = SceneScriptSharedBuffer<Float>(count: max(1, capacity) * Layout.stride, in: context),
              let dirty = SceneScriptSharedBuffer<UInt8>(count: max(1, capacity), in: context) else { return nil }
        self.capacity = capacity
        self.values = values
        self.dirty = dirty
    }

    /// Index of `field` of `slot` in `values`.
    static func index(slot: Int, field: Int) -> Int { slot * Layout.stride + field }

    /// Publishes the table as `__rt.table = {values, dirty, layout, capacity}`.
    func install(on rt: JSValue) {
        let table = JSValue(newObjectIn: rt.context)
        table?.setValue(values.value, forProperty: "values")
        table?.setValue(dirty.value, forProperty: "dirty")
        table?.setValue(Layout.javaScriptObject, forProperty: "layout")
        table?.setValue(capacity, forProperty: "capacity")
        rt.setValue(table, forProperty: "table")
    }
}
