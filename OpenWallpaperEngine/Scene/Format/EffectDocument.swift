import Foundation

/// Combo conditions on an effect pass, bind or FBO. WE authors a list of `{COMBO: value}` objects
/// (an empty object means "always"); a single object is accepted too.
typealias EffectConditions = [[String: Int]]

private func decodeConditions<K>(_ c: KeyedDecodingContainer<K>, key: K,
                                 userInfo: [CodingUserInfoKey: Any]) -> EffectConditions? {
    guard c.contains(key) else { return nil }
    switch c.decodeLogged(SceneJSON.self, forKey: key, userInfo: userInfo) {
    case .object?:
        return c.decodeEntries(Int.self, forKey: key, userInfo: userInfo).map { [$0] }
    case .array?:
        return c.decodeElements([String: Int].self, forKey: key, userInfo: userInfo)
    case nil, .null?:
        return nil
    case let other?:
        reportSkippedElement(userInfo, path: c.codingPath + [key],
                             error: DecodingError.dataCorrupted(.init(codingPath: c.codingPath + [key],
                                                                      debugDescription: "unsupported conditions \(other)")))
        return nil
    }
}

/// `effects/<name>/effect.json`: the pass graph of one effect.
struct EffectDocument: Decodable {
    var version: Int?
    var name: String?
    var description: String?
    var group: String?
    var replacementkey: String?
    var dependencies: [String]
    var passes: [EffectPass]
    var fbos: [EffectFBO]

    enum CodingKeys: String, CodingKey {
        case version, name, description, group, replacementkey, dependencies, passes, fbos
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let info = decoder.userInfo
        version = c.decodeLogged(Int.self, forKey: .version, userInfo: info)
        name = c.decodeLogged(String.self, forKey: .name, userInfo: info)
        description = c.decodeLogged(String.self, forKey: .description, userInfo: info)
        group = c.decodeLogged(String.self, forKey: .group, userInfo: info)
        replacementkey = c.decodeLogged(String.self, forKey: .replacementkey, userInfo: info)
        dependencies = c.decodeElements(String.self, forKey: .dependencies, userInfo: info) ?? []
        passes = c.decodeElements(EffectPass.self, forKey: .passes, userInfo: info) ?? []
        fbos = c.decodeElements(EffectFBO.self, forKey: .fbos, userInfo: info) ?? []
    }
}

/// One step of an effect: either a material draw into `target` (nil = the layer's ping-pong
/// buffer) or a `command` (`copy`/`swap`) from `source` to `target`.
struct EffectPass: Decodable {
    enum Command: String { case copy, swap }

    var material: String?
    var target: String?
    var bind: [EffectBind]
    /// Raw `command` string; see `commandKind`.
    var command: String?
    var source: String?
    var compose: Bool?
    var conditions: EffectConditions?

    var commandKind: Command? { command.flatMap { Command(rawValue: $0.lowercased()) } }

    enum CodingKeys: String, CodingKey { case material, target, bind, command, source, compose, conditions }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let info = decoder.userInfo
        material = c.decodeLogged(String.self, forKey: .material, userInfo: info)
        target = c.decodeLogged(String.self, forKey: .target, userInfo: info)
        bind = c.decodeElements(EffectBind.self, forKey: .bind, userInfo: info) ?? []
        command = c.decodeLogged(String.self, forKey: .command, userInfo: info)
        source = c.decodeLogged(String.self, forKey: .source, userInfo: info)
        compose = c.decodeLogged(Bool.self, forKey: .compose, userInfo: info)
        conditions = decodeConditions(c, key: .conditions, userInfo: info)
    }
}

/// Binds a named render target (`previous`, an FBO name or `_rt_*`) to a texture slot.
struct EffectBind: Decodable {
    var name: String
    var index: Int
    var conditions: EffectConditions?

    enum CodingKeys: String, CodingKey { case name, index, conditions }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        index = try c.decode(Int.self, forKey: .index)
        conditions = decodeConditions(c, key: .conditions, userInfo: decoder.userInfo)
    }
}

/// A render target an effect declares.
struct EffectFBO: Decodable {
    var name: String
    /// Divisor of the layer size.
    var scale: Int
    var fit: Int?
    var format: String
    var unique: Bool?
    var clear: String?
    var width: Int?
    var height: Int?
    var uvs: String?
    var conditions: EffectConditions?

    enum CodingKeys: String, CodingKey { case name, scale, fit, format, unique, clear, width, height, uvs, conditions }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let info = decoder.userInfo
        name = try c.decode(String.self, forKey: .name)
        scale = try c.decodeIfPresent(Int.self, forKey: .scale) ?? 1
        fit = c.decodeLogged(Int.self, forKey: .fit, userInfo: info)
        format = try c.decode(String.self, forKey: .format)
        unique = c.decodeLogged(Bool.self, forKey: .unique, userInfo: info)
        clear = c.decodeLogged(String.self, forKey: .clear, userInfo: info)
        width = c.decodeLogged(Int.self, forKey: .width, userInfo: info)
        height = c.decodeLogged(Int.self, forKey: .height, userInfo: info)
        uvs = c.decodeLogged(String.self, forKey: .uvs, userInfo: info)
        conditions = decodeConditions(c, key: .conditions, userInfo: info)
    }
}
