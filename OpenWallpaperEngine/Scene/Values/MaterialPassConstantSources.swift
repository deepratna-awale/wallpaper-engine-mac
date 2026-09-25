import Foundation

extension MaterialPass {
    /// The pass's material values by key, for `ShaderConstantResolver`: its
    /// `constantshadervalues` (literals or user-, script- or animation-bound), with each
    /// `usershadervalues` key bound to its user property. A user-bound key falls back to the
    /// constant, else to the declaring uniform's annotation default.
    func constantSources(uniforms: [ShaderUniformDeclaration]) -> [String: SceneValueSource] {
        var values = constantshadervalues.compactMapValues(\.valueSource)
        for (key, property) in usershadervalues ?? [:] {
            let declared = uniforms.first { $0.materialKey == key }
            let annotationDefault = declared.flatMap { $0.annotation["default"] }.flatMap(ShaderValue.init(json:))
            let fallback = values[key] ?? annotationDefault.map(SceneValueSource.literal)
            values[key] = .user(name: property, condition: nil, fallback: fallback ?? .literal(.zero))
        }
        return values
    }
}
