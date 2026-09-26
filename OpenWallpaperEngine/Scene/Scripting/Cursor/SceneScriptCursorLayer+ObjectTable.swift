import simd

extension SceneScriptCursorLayer {
    /// A hit-testable object (an image or text layer) in draw order, with what the object table
    /// doesn't hold.
    struct TableEntry {
        var slot: Int
        /// scene.json `disablepropagation`.
        var disablesPropagation: Bool

        init(slot: Int, disablesPropagation: Bool = false) {
            self.slot = slot
            self.disablesPropagation = disablesPropagation
        }
    }

    /// The layers of `drawOrder` (bottom first) as the object table holds them after the last
    /// frame: world matrix, size, origin, parallax depth, `solid` and `visible`, which scripts may
    /// have changed. `parentOf` names an object's parent slot, for visibility. Slots outside the
    /// table are skipped. On the runtime's thread, like every read of the table.
    static func layers(in table: SceneScriptObjectTable, drawOrder: [TableEntry],
                       parentOf: (Int) -> Int?) -> [SceneScriptCursorLayer] {
        drawOrder.compactMap { entry in
            guard (0..<table.capacity).contains(entry.slot) else { return nil }
            let slot = entry.slot
            let size = table[slot, .size], origin = table[slot, .origin], depth = table[slot, .parallaxDepth]
            return SceneScriptCursorLayer(
                slot: slot, worldMatrix: worldMatrix(in: table, slot: slot),
                size: SIMD2(size[0], size[1]), origin: SIMD2(origin[0], origin[1]),
                parallaxDepth: SIMD2(depth[0], depth[1]), isSolid: table[slot, .solid][0] != 0,
                disablesPropagation: entry.disablesPropagation,
                isVisible: isVisible(slot, in: table, parentOf: parentOf))
        }
    }

    private static func worldMatrix(in table: SceneScriptObjectTable, slot: Int) -> simd_float4x4 {
        let base = SceneScriptObjectTable.index(slot: slot, field: SceneScriptObjectTable.Layout.worldMatrix)
        func column(_ index: Int) -> SIMD4<Float> {
            SIMD4((0..<4).map { table.values[base + index * 4 + $0] })
        }
        return simd_float4x4(column(0), column(1), column(2), column(3))
    }

    /// `visible` of the object and every parent (0x140185010). A parent chain longer than the table
    /// is a cycle and counts as hidden.
    private static func isVisible(_ slot: Int, in table: SceneScriptObjectTable, parentOf: (Int) -> Int?) -> Bool {
        var current: Int? = slot
        var steps = 0
        while let object = current {
            guard (0..<table.capacity).contains(object), steps <= table.capacity else { return false }
            if table[object, .visible][0] == 0 { return false }
            current = parentOf(object)
            steps += 1
        }
        return true
    }
}
