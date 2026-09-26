import Foundation

enum APIConfig {
    private static let spicyKeyKey = "LiquidPlayer.spicyLyricsApiKey"
    private static let spotifyClientIdKey = "LiquidPlayer.spotifyClientId"
    private static let spotifyClientSecretKey = "LiquidPlayer.spotifyClientSecret"
    private static let spotifyRedirectUriKey = "LiquidPlayer.spotifyRedirectUri"
    // Default keys (Client key for Liquid Player; sensitive secrets kept empty)
    static let defaultSpicyLyricsApiKey = "sl_pk_pz-RiyRc7h3awnFVd-DybA9ulbh3-vSBxzzojOerWwM"
    static let defaultSpotifyClientId = "22c28b6eda464ae89cd44842e6e9e070"
    static let defaultSpotifyClientSecret = ""
    static let defaultSpotifyRedirectUri = "liquidplayer://callback"

    static var spicyLyricsApiKey: String {
        get {
            if let saved = UserDefaults.standard.string(forKey: spicyKeyKey), !saved.isEmpty {
                return saved
            }
            if let envKey = ProcessInfo.processInfo.environment["SPICY_LYRICS_API_KEY"], !envKey.isEmpty {
                return envKey
            }
            if let plistKey = Bundle.main.object(forInfoDictionaryKey: "SpicyLyricsApiKey") as? String, !plistKey.isEmpty {
                return plistKey
            }
            return defaultSpicyLyricsApiKey
        }
        set {
            UserDefaults.standard.set(newValue, forKey: spicyKeyKey)
        }
    }

    static var spotifyClientId: String {
        get {
            if let saved = UserDefaults.standard.string(forKey: spotifyClientIdKey), !saved.isEmpty {
                return saved
            }
            if let envKey = ProcessInfo.processInfo.environment["SPOTIFY_CLIENT_ID"], !envKey.isEmpty {
                return envKey
            }
            if let plistKey = Bundle.main.object(forInfoDictionaryKey: "SpotifyClientId") as? String, !plistKey.isEmpty {
                return plistKey
            }
            return defaultSpotifyClientId
        }
        set {
            UserDefaults.standard.set(newValue, forKey: spotifyClientIdKey)
        }
    }

    static var spotifyClientSecret: String {
        get {
            if let saved = UserDefaults.standard.string(forKey: spotifyClientSecretKey), !saved.isEmpty {
                return saved
            }
            if let envKey = ProcessInfo.processInfo.environment["SPOTIFY_CLIENT_SECRET"], !envKey.isEmpty {
                return envKey
            }
            if let plistKey = Bundle.main.object(forInfoDictionaryKey: "SpotifyClientSecret") as? String, !plistKey.isEmpty {
                return plistKey
            }
            return defaultSpotifyClientSecret
        }
        set {
            UserDefaults.standard.set(newValue, forKey: spotifyClientSecretKey)
        }
    }

    static var spotifyRedirectUri: String {
        get {
            UserDefaults.standard.string(forKey: spotifyRedirectUriKey) ?? defaultSpotifyRedirectUri
        }
        set {
            UserDefaults.standard.set(newValue, forKey: spotifyRedirectUriKey)
        }
    }

    static func resetToDefaults() {
        UserDefaults.standard.removeObject(forKey: spicyKeyKey)
        UserDefaults.standard.removeObject(forKey: spotifyClientIdKey)
        UserDefaults.standard.removeObject(forKey: spotifyClientSecretKey)
        UserDefaults.standard.removeObject(forKey: spotifyRedirectUriKey)
    }
}
