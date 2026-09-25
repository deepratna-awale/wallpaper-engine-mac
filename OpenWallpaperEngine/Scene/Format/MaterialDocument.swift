import Foundation

/// A material JSON (`materials/**.json`, `effects/<name>/materials/**.json`).
struct MaterialDocument: Decodable {
    var passes: [MaterialPass]

    enum CodingKeys: String, CodingKey { case passes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        passes = c.decodeElements(MaterialPass.self, forKey: .passes, userInfo: decoder.userInfo) ?? []
    }
}

/// One material pass: the shader plus its fixed-function state and defaults.
struct MaterialPass: Decodable {
    var shader: String
    var blending: String?
    var depthtest: String?
    var depthwrite: String?
    /// `cullmode`, or the older `culling` key.
    var cullmode: String?
    var alphawriting: String?
    /// Texture slots in order; nil entries are kept so indices stay aligned with the shader.
    var textures: [String?]
    var combos: [String: Int]
    var constantshadervalues: [String: SceneRawValue]
    /// Maps a shader uniform to a user property (e.g. `"schemecolor": "tint"`).
    var usershadervalues: [String: String]?

    enum CodingKeys: String, CodingKey {
        case shader, blending, depthtest, depthwrite, cullmode, culling, alphawriting
        case textures, combos, constantshadervalues, usershadervalues
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let info = decoder.userInfo
        shader = try c.decode(String.self, forKey: .shader)
        blending = c.decodeLogged(String.self, forKey: .blending, userInfo: info)
        depthtest = c.decodeLogged(String.self, forKey: .depthtest, userInfo: info)
        depthwrite = c.decodeLogged(String.self, forKey: .depthwrite, userInfo: info)
        cullmode = c.decodeLogged(String.self, forKey: .cullmode, userInfo: info)
            ?? c.decodeLogged(String.self, forKey: .culling, userInfo: info)
        alphawriting = c.decodeLogged(String.self, forKey: .alphawriting, userInfo: info)
        textures = c.decodeElements(String?.self, forKey: .textures, userInfo: info) ?? []
        combos = c.decodeEntries(Int.self, forKey: .combos, userInfo: info) ?? [:]
        constantshadervalues = c.decodeEntries(SceneRawValue.self, forKey: .constantshadervalues, userInfo: info) ?? [:]
        usershadervalues = c.decodeEntries(String.self, forKey: .usershadervalues, userInfo: info)
    }
}
