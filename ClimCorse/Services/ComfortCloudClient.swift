import Foundation

enum ClientError: LocalizedError {
    case notAuthenticated
    case server(status: Int, code: Int?, message: String)
    case malformedResponse
    case appVersionRejected

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Session Panasonic expirée. Reconnectez-vous."
        case .server(let status, let code, let message):
            let suffix = code.map { " (code \($0))" } ?? ""
            return "Panasonic a refusé la requête\(suffix) — HTTP \(status). \(message)"
        case .malformedResponse:
            return "Réponse inattendue du serveur Panasonic."
        case .appVersionRejected:
            return """
            Panasonic exige une version plus récente de l'application Comfort Cloud. \
            Mettez à jour le numéro de version dans les Réglages.
            """
        }
    }
}

/// Client de l'API de contrôle Comfort Cloud.
///
/// Toutes les requêtes passent par `execute`, qui rafraîchit le jeton au besoin
/// et signe chaque appel.
@MainActor
final class ComfortCloudClient {

    private let auth: ComfortCloudAuth
    private var session: Session?
    private(set) var appVersion: String

    /// Unités pour lesquelles la lecture en direct a échoué : on interroge le
    /// cache serveur pendant quelques cycles avant de retenter le direct.
    private var cachedReadsRemaining: [String: Int] = [:]
    private static let cachedReadCycles = 10

    // `ComfortCloudAuth` étant isolé sur le main actor, il ne peut pas servir
    // de valeur par défaut d'un paramètre : on l'instancie dans le corps.
    init(auth: ComfortCloudAuth? = nil,
         appVersion: String = ComfortCloud.defaultAppVersion) {
        let auth = auth ?? ComfortCloudAuth()
        auth.appVersion = appVersion
        self.auth = auth
        self.appVersion = appVersion
        self.session = Session.load()
    }

    var isAuthenticated: Bool { session != nil }

    func signIn() async throws {
        do {
            session = try await auth.signIn()
        } catch {
            // Le jeton a pu être acquis et enregistré avant l'échec : on le
            // reprend, pour que l'utilisateur n'ait pas à refaire la connexion
            // une fois le problème corrigé.
            session = Session.load()
            throw error
        }
    }

    func signOut() {
        Session.clear()
        session = nil
        cachedReadsRemaining.removeAll()
    }

    func setAppVersion(_ version: String) {
        appVersion = version
        auth.appVersion = version
    }

    // MARK: - Lecture

    /// Liste les unités pilotables du compte.
    func fetchDevices() async throws -> [DeviceInfo] {
        let json = try await execute(path: "device/group", method: "GET")
        guard let groups = json["groupList"] as? [[String: Any]] else {
            throw ClientError.malformedResponse
        }

        return groups.flatMap { group -> [DeviceInfo] in
            let devices = (group["deviceList"] as? [[String: Any]])
                ?? (group["deviceIdList"] as? [[String: Any]])
                ?? []
            return devices.compactMap { device in
                var enriched = device
                // Le nom du groupe vit au niveau du groupe, pas de l'appareil.
                if enriched["groupName"] == nil { enriched["groupName"] = group["groupName"] }
                return DeviceInfo(json: enriched)
            }
        }
    }

    /// Lit l'état d'une unité.
    ///
    /// On privilégie la lecture en direct, plus fraîche mais qui échoue quand
    /// l'unité est injoignable. Dans ce cas on bascule sur le cache serveur
    /// pour quelques cycles — le module Wi-Fi met du temps à se rétablir, et
    /// insister en direct à chaque rafraîchissement ne fait qu'accumuler les
    /// délais d'attente.
    func fetchState(for device: DeviceInfo) async throws -> (state: DeviceState, isStale: Bool) {
        let remaining = cachedReadsRemaining[device.guid]

        if remaining == nil || remaining! <= 0 {
            do {
                let json = try await execute(path: "deviceStatus/\(Self.encode(device.guid))", method: "GET")
                cachedReadsRemaining[device.guid] = nil
                return (DeviceState(json: json), false)
            } catch {
                cachedReadsRemaining[device.guid] = Self.cachedReadCycles
            }
        }

        let json = try await execute(path: "deviceStatus/now/\(Self.encode(device.guid))", method: "GET")
        cachedReadsRemaining[device.guid] = (cachedReadsRemaining[device.guid] ?? 1) - 1
        return (DeviceState(json: json), true)
    }

    // MARK: - Écriture

    /// Envoie un jeu de paramètres bruts à une unité.
    func control(_ guid: String, parameters: [String: Any]) async throws {
        _ = try await execute(path: "deviceStatus/control",
                              method: "POST",
                              body: ["deviceGuid": guid, "parameters": parameters])
    }

    func setPower(_ power: Power, on guid: String) async throws {
        try await control(guid, parameters: ["operate": power.rawValue])
    }

    func setMode(_ mode: OperationMode, on guid: String) async throws {
        // Changer de mode sur une unité éteinte n'a pas d'effet visible :
        // l'application officielle rallume, on fait de même.
        try await control(guid, parameters: [
            "operate": Power.on.rawValue,
            "operationMode": mode.rawValue
        ])
    }

    func setTargetTemperature(_ temperature: Double, on guid: String) async throws {
        try await control(guid, parameters: ["temperatureSet": temperature])
    }

    func setFanSpeed(_ speed: FanSpeed, on guid: String) async throws {
        try await control(guid, parameters: ["fanSpeed": speed.rawValue])
    }

    /// Règle l'oscillation verticale.
    ///
    /// `fanAutoMode` décrit l'état automatique des **deux** axes à la fois :
    /// il faut donc connaître l'axe horizontal courant pour ne pas l'écraser.
    func setVerticalSwing(_ swing: AirSwingUD, on guid: String, current: DeviceState) async throws {
        var parameters: [String: Any] = ["operate": Power.on.rawValue]
        let horizontalIsAuto = current.horizontalSwing == .auto

        if swing == .auto {
            parameters["fanAutoMode"] = (horizontalIsAuto ? AirSwingAutoMode.both : .airSwingUD).rawValue
        } else {
            parameters["airSwingUD"] = swing.rawValue
            parameters["fanAutoMode"] = (horizontalIsAuto ? AirSwingAutoMode.airSwingLR : .disabled).rawValue
        }
        try await control(guid, parameters: parameters)
    }

    /// Règle l'oscillation horizontale, symétriquement.
    func setHorizontalSwing(_ swing: AirSwingLR, on guid: String, current: DeviceState) async throws {
        var parameters: [String: Any] = ["operate": Power.on.rawValue]
        let verticalIsAuto = current.verticalSwing == .auto

        if swing == .auto {
            parameters["fanAutoMode"] = (verticalIsAuto ? AirSwingAutoMode.both : .airSwingLR).rawValue
        } else {
            parameters["airSwingLR"] = swing.rawValue
            parameters["fanAutoMode"] = (verticalIsAuto ? AirSwingAutoMode.airSwingUD : .disabled).rawValue
        }
        try await control(guid, parameters: parameters)
    }

    // MARK: - Transport

    @discardableResult
    private func execute(path: String,
                         method: String,
                         body: [String: Any]? = nil) async throws -> [String: Any] {
        var current = try await validSession()

        var (data, http) = try await send(path: path, method: method, body: body, session: current)

        // Un 401 malgré un jeton réputé valide arrive quand le serveur a
        // invalidé la session de son côté : on retente une fois après refresh.
        if http.statusCode == 401 {
            current = try await auth.refresh(current)
            session = current
            (data, http) = try await send(path: path, method: method, body: body, session: current)
        }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        guard (200...299).contains(http.statusCode) else {
            let code = json["code"] as? Int
            // 4106 : le serveur juge la version d'app annoncée trop ancienne.
            if code == 4106 { throw ClientError.appVersionRejected }
            throw ClientError.server(status: http.statusCode,
                                     code: code,
                                     message: json["message"] as? String
                                        ?? String(data: data, encoding: .utf8) ?? "")
        }
        return json
    }

    private func send(path: String,
                      method: String,
                      body: [String: Any]?,
                      session: Session) async throws -> (Data, HTTPURLResponse) {
        // Le GUID est déjà encodé dans `path` : le passer par URLComponents le
        // ré-encoderait une seconde fois.
        guard let url = URL(string: ComfortCloud.apiBaseURL.absoluteString + "/" + path) else {
            throw ClientError.malformedResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        RequestSigner.headers(accessToken: session.accessToken,
                              clientID: session.clientID,
                              appVersion: appVersion)
            .forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.malformedResponse }
        return (data, http)
    }

    private func validSession() async throws -> Session {
        guard var current = session else { throw ClientError.notAuthenticated }
        if current.isExpired {
            current = try await auth.refresh(current)
            session = current
        }
        // La connexion a pu s'interrompre entre l'obtention du jeton et celle du
        // `clientId` — un refus de version, typiquement. On rattrape ici plutôt
        // que d'imposer un nouveau passage par la page de Panasonic.
        if current.clientID == nil {
            current.clientID = try await auth.fetchClientID(accessToken: current.accessToken)
            current.save()
            session = current
        }
        return current
    }

    /// Prépare un GUID pour l'insérer dans un chemin d'URL.
    ///
    /// Les GUID Panasonic contiennent des `/` que le serveur attend transformés
    /// en `f` — pas échappés. Sans cette substitution, la lecture d'état échoue
    /// silencieusement sur certaines unités.
    private static func encode(_ guid: String) -> String {
        let normalized = guid.replacingOccurrences(of: "/", with: "f")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.")
        return normalized.addingPercentEncoding(withAllowedCharacters: allowed) ?? normalized
    }
}
