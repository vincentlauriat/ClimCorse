import Foundation

/// Constantes du protocole Panasonic Comfort Cloud.
///
/// Panasonic ne publie aucune API : ces valeurs sont celles de l'application
/// Android officielle (`com.panasonic.ACCsmart`), telles qu'utilisées par les
/// clients open source maintenus (`aio-panasonic-comfort-cloud`).
enum ComfortCloud {

    // MARK: - Points d'entrée

    static let authBaseURL = URL(string: "https://authglb.digital.panasonic.com")!
    static let apiBaseURL = URL(string: "https://accsmart.panasonic.com")!

    // MARK: - Identité OAuth de l'application Android

    static let clientID = "Xmy6xIYIitMxngjB2rHvlm6HSDNnaMJx"
    static let redirectURI = "panasonic-iot-cfc://authglb.digital.panasonic.com/android/com.panasonic.ACCsmart/callback"
    static let redirectScheme = "panasonic-iot-cfc"

    /// En-tête `Auth0-Client` attendu par le tenant Auth0 de Panasonic.
    /// Base64 de `{"name":"Auth0.Android","env":{"android":"30"},"version":"2.9.3"}`.
    static let auth0Client = "eyJuYW1lIjoiQXV0aDAuQW5kcm9pZCIsImVudiI6eyJhbmRyb2lkIjoiMzAifSwidmVyc2lvbiI6IjIuOS4zIn0="

    /// Scopes demandés à l'autorisation. L'échange du code, lui, ne demande
    /// que `openid` — cette asymétrie est celle du client officiel, la
    /// reproduire évite un refus côté serveur.
    static let authorizeScope = "openid offline_access comfortcloud.control a2w.control"
    static let tokenScope = "openid"

    static var audience: String { "https://digital.panasonic.com/\(clientID)/api/v1/" }

    // MARK: - En-têtes

    static let authAPIUserAgent = "okhttp/4.10.0"
    static let authBrowserUserAgent =
        "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/113.0.0.0 Mobile Safari/537.36"

    /// Version de l'app Android annoncée dans `x-app-version`.
    ///
    /// Le serveur rejette les versions qu'il juge périmées (code 4106). Les
    /// clients Python scrutent le Play Store pour suivre ; on préfère ici une
    /// constante surchargeable depuis les Réglages : scraper une page web
    /// depuis une app notarisée est un piège de maintenance.
    ///
    /// Relevée sur le Play Store le 2026-08-11. La valeur `1.21.0` que portent
    /// encore les clients Python est refusée par le serveur.
    static let defaultAppVersion = "4.4.0"

    /// Sel utilisé dans le calcul de `x-cfc-api-key`.
    static let apiKeySalt = "521325fb2dd486bf4831b47644317fca"

    /// Valeur sentinelle renvoyée quand une sonde de température est absente
    /// ou hors ligne — ce n'est pas une mesure, il faut la masquer.
    static let invalidTemperature: Double = 126
}

// MARK: - Énumérations du protocole

enum Power: Int, Codable, CaseIterable {
    case off = 0
    case on = 1
}

enum OperationMode: Int, Codable, CaseIterable {
    case auto = 0
    case dry = 1
    case cool = 2
    case heat = 3
    case fan = 4
}

enum FanSpeed: Int, Codable, CaseIterable {
    case auto = 0
    case low = 1
    case lowMid = 2
    case mid = 3
    case highMid = 4
    case high = 5
}

enum AirSwingUD: Int, Codable, CaseIterable {
    case auto = -1
    case up = 0
    case upMid = 3
    case mid = 2
    case downMid = 4
    case down = 1
    case swing = 5
}

enum AirSwingLR: Int, Codable, CaseIterable {
    case auto = -1
    case left = 1
    case leftMid = 5
    case mid = 2
    case rightMid = 4
    case right = 0
    case unavailable = 6
}

/// Encodage du mode automatique d'oscillation. Le serveur ne stocke pas
/// « auto » dans `airSwingLR`/`airSwingUD` : il l'exprime par ce champ séparé,
/// qui se comporte comme un masque de bits (LR = 1, UD = 2).
enum AirSwingAutoMode: Int, Codable {
    case both = 0
    case disabled = 1
    case airSwingUD = 2
    case airSwingLR = 3
}

enum EcoMode: Int, Codable, CaseIterable {
    case auto = 0
    case powerful = 1
    case quiet = 2
}

enum NanoeMode: Int, Codable, CaseIterable {
    case unavailable = 0
    case off = 1
    case on = 2
    case modeG = 3
    case all = 4
}

enum DataMode: Int, Codable {
    case day = 0
    case week = 1
    case month = 2
    case year = 4
}
