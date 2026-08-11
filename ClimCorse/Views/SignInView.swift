import SwiftUI

struct SignInView: View {
    @EnvironmentObject private var viewModel: ClimateViewModel
    @State private var isSigningIn = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wind")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("ClimCorse")
                .font(.largeTitle.weight(.medium))

            Text("""
                Connectez-vous à votre compte Panasonic Comfort Cloud pour piloter \
                vos climatiseurs.
                """)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)

            Button {
                isSigningIn = true
                Task {
                    await viewModel.signIn()
                    isSigningIn = false
                }
            } label: {
                if isSigningIn {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Se connecter")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSigningIn)

            // La saisie se fait dans la page de Panasonic : l'application ne
            // voit ni le mot de passe ni le code de double authentification.
            Text("La connexion s'ouvre sur le site de Panasonic. ClimCorse n'a jamais accès à votre mot de passe.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
