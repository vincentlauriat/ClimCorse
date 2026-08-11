import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var viewModel: ClimateViewModel
    @State private var appVersion: String = ""

    var body: some View {
        Form {
            Section("Rafraîchissement") {
                Picker("Intervalle", selection: $viewModel.refreshInterval) {
                    Text("60 secondes").tag(60.0)
                    Text("2 minutes").tag(120.0)
                    Text("5 minutes").tag(300.0)
                }
                Text("""
                    Panasonic limite le nombre de requêtes par compte. Un intervalle \
                    court n'apporte rien — les unités ne remontent leur état que \
                    toutes les quelques minutes — et expose à un blocage temporaire.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Compatibilité") {
                TextField("Version de l'app Comfort Cloud", text: $appVersion)
                    .onSubmit { viewModel.updateAppVersion(appVersion) }
                Text("""
                    Le serveur refuse les clients qu'il juge trop anciens. Si ClimCorse \
                    signale un refus de version, relevez le numéro de version de \
                    l'application Comfort Cloud sur le Play Store et saisissez-le ici.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Compte") {
                HStack {
                    Text(viewModel.isAuthenticated ? "Connecté à Comfort Cloud" : "Non connecté")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if viewModel.isAuthenticated {
                        Button("Se déconnecter", role: .destructive) { viewModel.signOut() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { appVersion = viewModel.appVersion }
    }
}
