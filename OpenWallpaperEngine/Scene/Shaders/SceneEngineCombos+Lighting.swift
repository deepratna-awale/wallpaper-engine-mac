import Foundation

extension SceneEngineCombos {
    /// `LIGHTS_*`, `LIGHTS_SHADOW_MAPPING`, `LIGHTS_SHADOW_MAPPING_QUALITY` and `LIGHTS_COOKIE`
    /// from `lightBudget` and `shadowQuality` when the material's `LIGHTING` is on, and
    /// `SCENE_ORTHO` (docs/lighting-plan.md §2.2). None yet.
    func lightingCombos(for material: [String: Int]) -> [String: Int] {
        [:]
    }
}
