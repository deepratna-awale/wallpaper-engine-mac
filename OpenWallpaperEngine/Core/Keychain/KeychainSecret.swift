import Foundation

/// One secret in the keychain that older builds kept in `UserDefaults`.
///
/// The first `load()` moves a leftover defaults value into the keychain and deletes it from
/// defaults, so the plain-text copy is gone after one launch. Errors are logged without the value.
struct KeychainSecret {
    let keychain: KeychainStore
    let account: String
    /// Where builds before the keychain move stored this value.
    let legacyDefaultsKey: String
    let defaults: UserDefaults

    /// A service name under the app's bundle identifier, e.g. `<bundle id>.steam-web-api-key`.
    static func service(_ suffix: String, bundle: Bundle = .main) -> String {
        "\(bundle.bundleIdentifier ?? "com.winddog.wallpaper-engine").\(suffix)"
    }

    /// The stored value, or `nil` when there is none or the keychain can't be read.
    func load() -> String? {
        migrateFromDefaultsIfNeeded()
        do {
            guard let value = try keychain.string(forAccount: account), !value.isEmpty else { return nil }
            return value
        } catch {
            OWELog.error(.settings, "Can't read \(account) from \(keychain.service): \(error)")
            return nil
        }
    }

    func save(_ value: String) throws {
        try keychain.set(value, forAccount: account)
        defaults.removeObject(forKey: legacyDefaultsKey)
    }

    func remove() throws {
        try keychain.removeValue(forAccount: account)
        defaults.removeObject(forKey: legacyDefaultsKey)
    }

    /// Moves a plain-text defaults value into the keychain once. A value already in the keychain
    /// wins; the defaults copy is deleted only after the keychain holds the secret.
    func migrateFromDefaultsIfNeeded() {
        guard defaults.object(forKey: legacyDefaultsKey) != nil else { return }
        let legacy = defaults.string(forKey: legacyDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        do {
            if !legacy.isEmpty, try keychain.string(forAccount: account) == nil {
                try keychain.set(legacy, forAccount: account)
                OWELog.info(.settings, "Moved \(account) from user defaults into the keychain")
            }
            defaults.removeObject(forKey: legacyDefaultsKey)
        } catch {
            OWELog.error(.settings, "Can't move \(account) into \(keychain.service); keeping it in user defaults: \(error)")
        }
    }
}
