import Combine
import Sparkle
import SwiftUI

/// Enveloppe SwiftUI autour de l'updater Sparkle.
///
/// Sparkle est piloté par `SPUStandardUpdaterController`, une classe AppKit :
/// cette enveloppe se contente d'exposer son état de disponibilité pour que
/// l'entrée de menu se grise pendant qu'une vérification est déjà en cours.
@MainActor
final class Updater: ObservableObject {

    /// Vrai quand une vérification manuelle peut être lancée.
    @Published private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController

    init() {
        // `startingUpdater: true` déclenche la vérification automatique au
        // lancement, conformément à SUEnableAutomaticChecks.
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
