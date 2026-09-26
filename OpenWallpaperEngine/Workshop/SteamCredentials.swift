import Foundation

/// The Steam secrets this app keeps, all in the keychain.
///
/// - The Web API key (Workshop browse/search and `GetPlayerSummaries`).
/// - The steamcmd account name, so the cached steamcmd session can be reused at launch.
///
/// The Steam password and Steam Guard codes are never stored: they are piped to steamcmd once,
/// and steamcmd keeps its own login token for later sessions (it never stores the password).
enum SteamCredentials {
    static func webAPIKey(defaults: UserDefaults = .standard) -> KeychainSecret {
        KeychainSecret(
            keychain: KeychainStore(service: KeychainSecret.service("steam-web-api-key")),
            account: "SteamWebAPIKey",
            legacyDefaultsKey: "SteamWebAPIKey",
            defaults: defaults
        )
    }

    static func steamCmdAccount(defaults: UserDefaults = .standard) -> KeychainSecret {
        KeychainSecret(
            keychain: KeychainStore(service: KeychainSecret.service("steamcmd-account")),
            account: "SteamLastUsername",
            legacyDefaultsKey: "SteamLastUsername",
            defaults: defaults
        )
    }
}
