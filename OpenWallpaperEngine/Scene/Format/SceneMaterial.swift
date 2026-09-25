import Foundation

struct WEModel: Codable {
    var autosize: Bool?
    var material: String?    // path to material JSON
    var puppet: String?      // path to a Puppet Warp rig (.mdl); unsupported, rendered as a flat atlas otherwise
}

struct WEMaterial: Decodable {
    var passes: [WEMaterialPass]?
}

struct WEMaterialPass: Decodable {
    var blending: String?    // "translucent", "additive"
    var shader: String?
    var textures: [String]?
    var cullmode: String?
    var depthtest: String?
    var depthwrite: String?
    var constants: [String: WEScriptValue]?

    enum CodingKeys: String, CodingKey {
        case blending, shader, textures, cullmode, depthtest, depthwrite, constants, constantshadervalues
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        blending = try container.decodeIfPresent(String.self, forKey: .blending)
        shader = try container.decodeIfPresent(String.self, forKey: .shader)
        textures = try container.decodeIfPresent([String].self, forKey: .textures)
        cullmode = try container.decodeIfPresent(String.self, forKey: .cullmode)
        depthtest = try container.decodeIfPresent(String.self, forKey: .depthtest)
        depthwrite = try container.decodeIfPresent(String.self, forKey: .depthwrite)
        constants = try container.decodeIfPresent([String: WEScriptValue].self, forKey: .constants)
            ?? container.decodeIfPresent([String: WEScriptValue].self, forKey: .constantshadervalues)
    }
}

// MARK: - Particle System
