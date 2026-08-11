import Foundation
import SwiftUI

/// État de l'application et orchestration des appels réseau.
@MainActor
final class ClimateViewModel: ObservableObject {

    @Published private(set) var devices: [ClimateDevice] = []
    @Published private(set) var isAuthenticated: Bool
    @Published private(set) var isLoading = false
    @Published private(set) var lastRefresh: Date?
    @Published var errorMessage: String?

    /// Intervalle de rafraîchissement, en secondes.
    ///
    /// Comfort Cloud n'est pas fait pour être interrogé en continu et sanctionne
    /// les clients trop bavards. 120 s est la valeur par défaut de l'intégration
    /// Home Assistant de référence ; descendre sous 30 s expose à un blocage du
    /// compte.
    ///
    /// `@AppStorage` ne conviendrait pas ici : hors d'une `View`, il ne
    /// déclenche pas `objectWillChange` et l'interface ne suivrait pas.
    @Published var refreshInterval: Double {
        didSet {
            UserDefaults.standard.set(refreshInterval, forKey: Defaults.refreshInterval)
            restartPolling()
        }
    }

    @Published private(set) var appVersion: String

    private enum Defaults {
        static let refreshInterval = "refreshInterval"
        static let appVersion = "appVersion"
    }

    private let client: ComfortCloudClient
    private var pollingTask: Task<Void, Never>?
    /// Écritures de consigne en attente, par unité — permet d'annuler la
    /// précédente quand l'utilisateur fait encore glisser le curseur.
    private var pendingSetpoints: [String: Task<Void, Never>] = [:]

    init(client: ComfortCloudClient? = nil) {
        let defaults = UserDefaults.standard
        let interval = defaults.double(forKey: Defaults.refreshInterval)
        self.refreshInterval = interval > 0 ? interval : 120
        let version = defaults.string(forKey: Defaults.appVersion) ?? ComfortCloud.defaultAppVersion
        self.appVersion = version

        let client = client ?? ComfortCloudClient()
        self.client = client
        self.isAuthenticated = client.isAuthenticated
        client.setAppVersion(version)
    }

    // MARK: - Session

    func signIn() async {
        do {
            try await client.signIn()
            isAuthenticated = true
            await refresh()
            startPolling()
        } catch AuthError.cancelled {
            // L'utilisateur a fermé la fenêtre de connexion : ce n'est pas une erreur.
        } catch {
            errorMessage = error.localizedDescription
            // Une connexion peut échouer après coup tout en ayant obtenu un
            // jeton valide : on reflète l'état réel de la session plutôt que
            // de renvoyer l'utilisateur sur l'écran de connexion.
            isAuthenticated = client.isAuthenticated
            if isAuthenticated { startPolling() }
        }
    }

    func signOut() {
        pollingTask?.cancel()
        pollingTask = nil
        client.signOut()
        devices = []
        isAuthenticated = false
    }

    func updateAppVersion(_ version: String) {
        let trimmed = version.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        appVersion = trimmed
        UserDefaults.standard.set(trimmed, forKey: Defaults.appVersion)
        client.setAppVersion(trimmed)
        // Corriger la version sert précisément à débloquer un refus serveur :
        // on retente sans attendre le prochain cycle de sondage.
        Task { await refresh() }
    }

    // MARK: - Rafraîchissement

    func refresh() async {
        guard isAuthenticated, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let infos = try await client.fetchDevices()
            var refreshed: [ClimateDevice] = []

            for info in infos {
                do {
                    let (state, isStale) = try await client.fetchState(for: info)
                    refreshed.append(ClimateDevice(info: info, state: state, isStale: isStale))
                } catch {
                    // Une unité injoignable ne doit pas faire disparaître les
                    // autres : on conserve son dernier état connu.
                    if let previous = devices.first(where: { $0.id == info.guid }) {
                        refreshed.append(ClimateDevice(info: info, state: previous.state, isStale: true))
                    }
                }
            }

            devices = refreshed
            lastRefresh = Date()
            errorMessage = nil
        } catch ClientError.notAuthenticated {
            isAuthenticated = false
            errorMessage = ClientError.notAuthenticated.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startPolling() {
        guard isAuthenticated, pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.refreshInterval))
                guard !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    private func restartPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        startPolling()
    }

    // MARK: - Commandes

    /// Applique une commande en affichant tout de suite le résultat attendu.
    ///
    /// L'aller-retour vers le cloud prend plusieurs secondes ; sans cette mise
    /// à jour locale immédiate, l'interface paraît figée et l'utilisateur
    /// clique deux fois. En cas d'échec, on rétablit l'état précédent.
    private func apply(to guid: String,
                       optimistic: (inout DeviceState) -> Void,
                       send: @escaping (DeviceState) async throws -> Void) {
        guard let index = devices.firstIndex(where: { $0.id == guid }) else { return }
        let previous = devices[index].state

        var updated = previous
        optimistic(&updated)
        devices[index].state = updated

        let rollback = Self.rollback(from: previous, to: updated)

        Task {
            do {
                try await send(previous)
            } catch {
                if let index = devices.firstIndex(where: { $0.id == guid }) {
                    rollback(&devices[index].state)
                }
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Construit l'annulation d'une commande optimiste.
    ///
    /// Restaurer l'état complet serait faux : entre l'envoi et l'échec,
    /// l'utilisateur a pu changer autre chose — annuler un changement de mode
    /// remettrait alors aussi l'ancienne consigne. On ne rétablit donc que les
    /// champs que cette commande avait modifiés, et seulement s'ils portent
    /// encore la valeur qu'elle avait posée : sinon une commande plus récente a
    /// pris le relais et doit primer.
    private static func rollback(from previous: DeviceState,
                                 to applied: DeviceState) -> (inout DeviceState) -> Void {
        var restorers: [(inout DeviceState) -> Void] = []

        func track<V: Equatable>(_ keyPath: WritableKeyPath<DeviceState, V>) {
            let old = previous[keyPath: keyPath]
            let new = applied[keyPath: keyPath]
            guard old != new else { return }
            restorers.append { state in
                if state[keyPath: keyPath] == new { state[keyPath: keyPath] = old }
            }
        }

        track(\.power)
        track(\.mode)
        track(\.fanSpeed)
        track(\.targetTemperature)
        track(\.horizontalSwing)
        track(\.verticalSwing)
        track(\.ecoMode)
        track(\.nanoe)

        return { state in restorers.forEach { $0(&state) } }
    }

    func togglePower(_ device: ClimateDevice) {
        let target: Power = device.state.power == .on ? .off : .on
        apply(to: device.id) { $0.power = target } send: { [client] _ in
            try await client.setPower(target, on: device.id)
        }
    }

    func setMode(_ mode: OperationMode, on device: ClimateDevice) {
        apply(to: device.id) {
            $0.mode = mode
            $0.power = .on
        } send: { [client] _ in
            try await client.setMode(mode, on: device.id)
        }
    }

    func setFanSpeed(_ speed: FanSpeed, on device: ClimateDevice) {
        apply(to: device.id) { $0.fanSpeed = speed } send: { [client] _ in
            try await client.setFanSpeed(speed, on: device.id)
        }
    }

    func setVerticalSwing(_ swing: AirSwingUD, on device: ClimateDevice) {
        apply(to: device.id) {
            $0.verticalSwing = swing
            $0.power = .on
        } send: { [client] previous in
            try await client.setVerticalSwing(swing, on: device.id, current: previous)
        }
    }

    func setHorizontalSwing(_ swing: AirSwingLR, on device: ClimateDevice) {
        apply(to: device.id) {
            $0.horizontalSwing = swing
            $0.power = .on
        } send: { [client] previous in
            try await client.setHorizontalSwing(swing, on: device.id, current: previous)
        }
    }

    /// Règle la consigne, en n'envoyant que la valeur finale.
    ///
    /// Un curseur déplacé de 19 à 24 °C produirait cinq appels réseau ; on
    /// n'émet que le dernier, une fois le geste stabilisé.
    func setTargetTemperature(_ temperature: Double, on device: ClimateDevice) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        devices[index].state.targetTemperature = temperature

        pendingSetpoints[device.id]?.cancel()
        pendingSetpoints[device.id] = Task { [weak self, client] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            do {
                try await client.setTargetTemperature(temperature, on: device.id)
            } catch {
                await MainActor.run { self?.errorMessage = error.localizedDescription }
            }
        }
    }
}
