import CryptoKit
import Foundation

/// Construit les en-têtes signés attendus par `accsmart.panasonic.com`.
///
/// Chaque appel porte un `x-cfc-api-key` dérivé de l'horodatage et du jeton.
/// Le serveur recalcule la même empreinte de son côté ; toute divergence — ne
/// serait-ce que d'une seconde ou d'un fuseau — se solde par un 401.
enum RequestSigner {

    /// Formate l'instant courant dans le **fuseau local**, comme le fait le
    /// client officiel.
    private static let localFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    /// Relit cette même chaîne **comme si elle était en UTC**.
    private static let utcFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// Horodatage envoyé dans `x-app-timestamp`, en heure locale.
    static func timestamp(for date: Date = Date()) -> String {
        localFormatter.string(from: date)
    }

    /// Calcule `x-cfc-api-key`.
    ///
    /// Subtilité indispensable : l'horodatage est produit en heure **locale**,
    /// puis réinterprété en **UTC** pour obtenir les millisecondes. Ce décalage
    /// n'est pas une erreur de notre part — c'est le comportement du client
    /// officiel, et le serveur attend exactement ce résultat. Le corriger
    /// ferait échouer toutes les requêtes hors du fuseau UTC.
    static func apiKey(timestamp: String, accessToken: String) -> String? {
        guard let reinterpreted = utcFormatter.date(from: timestamp) else { return nil }
        let milliseconds = String(Int(reinterpreted.timeIntervalSince1970 * 1000))

        var input = Data()
        input.append(Data("Comfort Cloud".utf8))
        input.append(Data(ComfortCloud.apiKeySalt.utf8))
        input.append(Data(milliseconds.utf8))
        input.append(Data("Bearer ".utf8))
        input.append(Data(accessToken.utf8))

        let digest = SHA256.hash(data: input)
        let hex = digest.map { String(format: "%02x", $0) }.joined()

        // Le client officiel insère « cfc » après le 9e caractère.
        let cut = hex.index(hex.startIndex, offsetBy: 9)
        return hex[..<cut] + "cfc" + hex[cut...]
    }

    /// En-têtes complets d'un appel authentifié à l'API de contrôle.
    static func headers(accessToken: String,
                        clientID: String?,
                        appVersion: String,
                        date: Date = Date()) -> [String: String] {
        let stamp = timestamp(for: date)
        var headers = [
            "content-type": "application/json;charset=utf-8",
            "user-agent": "G-RAC",
            "x-app-name": "Comfort Cloud",
            "x-app-timestamp": stamp,
            "x-app-type": "1",
            "x-app-version": appVersion,
            "x-user-authorization-v2": "Bearer \(accessToken)"
        ]
        if let key = apiKey(timestamp: stamp, accessToken: accessToken) {
            headers["x-cfc-api-key"] = key
        }
        if let clientID, !clientID.isEmpty {
            headers["x-client-id"] = clientID
        }
        return headers
    }
}
