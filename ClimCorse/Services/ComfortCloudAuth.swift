import AuthenticationServices
import CryptoKit
import Foundation

enum AuthError: LocalizedError {
    case cancelled
    case missingCode
    case network(String)
    case server(status: Int, body: String)
    case notAuthenticated
    case appVersionRejected

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Connexion annulée."
        case .missingCode:
            return "Panasonic n'a pas renvoyé de code d'autorisation."
        case .network(let message):
            return "Erreur réseau : \(message)"
        case .server(let status, let body):
            return "Le serveur Panasonic a répondu \(status) : \(body)"
        case .notAuthenticated:
            return "Aucune session valide. Connectez-vous à votre compte Panasonic."
        case .appVersionRejected:
            return """
            Panasonic refuse cette version de client (« New version app has been \
            published »). Ouvrez les Réglages et indiquez le numéro de version \
            actuel de l'application Comfort Cloud sur le Play Store, puis \
            actualisez — votre connexion reste valide.
            """
        }
    }
}

/// Jetons d'une session Comfort Cloud, persistés dans le trousseau.
struct Session {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var scope: String
    var clientID: String?

    /// On rafraîchit un peu avant l'échéance : une requête signée juste à la
    /// limite se ferait rejeter le temps qu'elle atteigne le serveur.
    var isExpired: Bool { Date() >= expiresAt.addingTimeInterval(-60) }

    static func load() -> Session? {
        guard let access = Keychain.get(SessionKey.accessToken),
              let refresh = Keychain.get(SessionKey.refreshToken),
              let expiresRaw = Keychain.get(SessionKey.expiresAt),
              let expires = TimeInterval(expiresRaw) else { return nil }
        return Session(accessToken: access,
                       refreshToken: refresh,
                       expiresAt: Date(timeIntervalSince1970: expires),
                       scope: Keychain.get(SessionKey.scope) ?? ComfortCloud.tokenScope,
                       clientID: Keychain.get(SessionKey.clientID))
    }

    func save() {
        Keychain.set(accessToken, for: SessionKey.accessToken)
        Keychain.set(refreshToken, for: SessionKey.refreshToken)
        Keychain.set(String(expiresAt.timeIntervalSince1970), for: SessionKey.expiresAt)
        Keychain.set(scope, for: SessionKey.scope)
        if let clientID { Keychain.set(clientID, for: SessionKey.clientID) }
    }

    static func clear() {
        [SessionKey.accessToken, SessionKey.refreshToken, SessionKey.expiresAt,
         SessionKey.scope, SessionKey.clientID].forEach(Keychain.remove)
    }
}

/// Authentification OAuth 2.0 avec PKCE contre le tenant Auth0 de Panasonic.
///
/// La page de connexion est présentée par le système
/// (`ASWebAuthenticationSession`) : Panasonic gère lui-même le mot de passe et
/// la double authentification, et l'application ne voit jamais les
/// identifiants. C'est aussi ce qui nous évite de rejouer le formulaire HTML
/// d'Auth0 comme le font les clients Python — un scraping qui casse à chaque
/// refonte de leur page.
@MainActor
final class ComfortCloudAuth: NSObject {

    private var webAuthSession: ASWebAuthenticationSession?

    /// Version d'app annoncée au serveur, tenue à jour par le client.
    var appVersion: String = ComfortCloud.defaultAppVersion

    // MARK: - Connexion interactive

    func signIn() async throws -> Session {
        let verifier = Self.randomString(length: 43)
        let challenge = Self.codeChallenge(for: verifier)
        let state = Self.randomString(length: 20)

        let code = try await requestAuthorizationCode(challenge: challenge, state: state)
        var session = try await exchange(code: code, verifier: verifier)

        // On enregistre dès maintenant : le jeton est acquis et coûte un
        // passage complet par la page de Panasonic. Si la récupération du
        // `clientId` échoue — typiquement un refus de version — le jeton
        // resterait sinon perdu et il faudrait tout recommencer.
        session.save()

        session.clientID = try await fetchClientID(accessToken: session.accessToken)
        session.save()
        return session
    }

    private func requestAuthorizationCode(challenge: String, state: String) async throws -> String {
        var components = URLComponents(
            url: ComfortCloud.authBaseURL.appendingPathComponent("authorize"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "scope", value: ComfortCloud.authorizeScope),
            URLQueryItem(name: "audience", value: ComfortCloud.audience),
            URLQueryItem(name: "protocol", value: "oauth2"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "auth0Client", value: ComfortCloud.auth0Client),
            URLQueryItem(name: "client_id", value: ComfortCloud.clientID),
            URLQueryItem(name: "redirect_uri", value: ComfortCloud.redirectURI),
            URLQueryItem(name: "state", value: state)
        ]

        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: components.url!,
                callbackURLScheme: ComfortCloud.redirectScheme
            ) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else if let error = error as? ASWebAuthenticationSessionError,
                          error.code == .canceledLogin {
                    continuation.resume(throwing: AuthError.cancelled)
                } else {
                    continuation.resume(throwing: AuthError.network(
                        error?.localizedDescription ?? "session interrompue"))
                }
            }
            session.presentationContextProvider = self
            // Une session éphémère repart d'un état vierge : sans cela, un
            // compte déjà connecté dans Safari court-circuite le choix du compte.
            session.prefersEphemeralWebBrowserSession = false
            self.webAuthSession = session
            session.start()
        }

        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw AuthError.missingCode
        }
        return code
    }

    // MARK: - Échange et rafraîchissement

    private func exchange(code: String, verifier: String) async throws -> Session {
        // Daté avant l'appel : mieux vaut une expiration légèrement pessimiste
        // qu'un jeton considéré valide une seconde de trop.
        let requestedAt = Date()
        let payload: [String: Any] = [
            "scope": ComfortCloud.tokenScope,
            "client_id": ComfortCloud.clientID,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": ComfortCloud.redirectURI,
            "code_verifier": verifier
        ]
        return try await postToken(payload, requestedAt: requestedAt)
    }

    func refresh(_ session: Session) async throws -> Session {
        let requestedAt = Date()
        let payload: [String: Any] = [
            "scope": session.scope,
            "client_id": ComfortCloud.clientID,
            "refresh_token": session.refreshToken,
            "grant_type": "refresh_token"
        ]
        var refreshed = try await postToken(payload, requestedAt: requestedAt)
        refreshed.clientID = session.clientID
        refreshed.save()
        return refreshed
    }

    private func postToken(_ payload: [String: Any], requestedAt: Date) async throws -> Session {
        var request = URLRequest(url: ComfortCloud.authBaseURL.appendingPathComponent("oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(ComfortCloud.auth0Client, forHTTPHeaderField: "Auth0-Client")
        request.setValue(ComfortCloud.authAPIUserAgent, forHTTPHeaderField: "user-agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let refreshToken = json["refresh_token"] as? String,
              let expiresIn = json["expires_in"] as? TimeInterval else {
            throw AuthError.missingCode
        }

        return Session(accessToken: accessToken,
                       refreshToken: refreshToken,
                       expiresAt: requestedAt.addingTimeInterval(expiresIn),
                       scope: json["scope"] as? String ?? ComfortCloud.tokenScope,
                       clientID: nil)
    }

    /// Second temps de la connexion : l'API de contrôle exige un `x-client-id`
    /// distinct du jeton OAuth, obtenu par cet appel.
    func fetchClientID(accessToken: String) async throws -> String {
        var request = URLRequest(url: ComfortCloud.apiBaseURL.appendingPathComponent("auth/v2/login"))
        request.httpMethod = "POST"
        RequestSigner.headers(accessToken: accessToken, clientID: nil, appVersion: appVersion)
            .forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["language": 0])

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientID = json["clientId"] as? String else {
            throw AuthError.missingCode
        }
        return clientID
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            // Le serveur signale par le code 4106 que le client qu'on prétend
            // être est trop ancien. Le message brut (« New version app has been
            // published ») n'indique rien d'actionnable à l'utilisateur.
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if json?["code"] as? Int == 4106 { throw AuthError.appVersionRejected }

            throw AuthError.server(status: http.statusCode,
                                   body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    // MARK: - PKCE

    private static func randomString(length: Int) -> String {
        let alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension ComfortCloudAuth: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        }
    }
}
