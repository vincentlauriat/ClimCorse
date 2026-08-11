import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: ClimateViewModel
    @State private var selection: String?

    var body: some View {
        Group {
            if viewModel.isAuthenticated {
                deviceBrowser
            } else {
                SignInView()
            }
        }
        .task {
            guard viewModel.isAuthenticated else { return }
            await viewModel.refresh()
            viewModel.startPolling()
        }
        .alert("Erreur", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private var deviceBrowser: some View {
        NavigationSplitView {
            List(viewModel.devices, selection: $selection) { device in
                DeviceRowView(device: device).tag(device.id)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .overlay {
                if viewModel.devices.isEmpty && !viewModel.isLoading {
                    ContentUnavailableView(
                        "Aucun climatiseur",
                        systemImage: "wind",
                        description: Text("Aucune unité pilotable n'est associée à ce compte Panasonic.")
                    )
                }
            }
        } detail: {
            if let selection, let device = viewModel.devices.first(where: { $0.id == selection }) {
                DeviceDetailView(device: device)
            } else {
                ContentUnavailableView(
                    "Sélectionnez un climatiseur",
                    systemImage: "sidebar.left",
                    description: Text("Choisissez une unité dans la liste pour la piloter.")
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Label("Actualiser", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isLoading)
            }
        }
        .onAppear {
            if selection == nil { selection = viewModel.devices.first?.id }
        }
    }
}

/// Ligne de la liste latérale.
struct DeviceRowView: View {
    let device: ClimateDevice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.state.power == .on ? device.state.mode.symbol : "power")
                .foregroundStyle(device.state.power == .on
                                 ? AnyShapeStyle(.tint)
                                 : AnyShapeStyle(.secondary))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.info.name)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if device.isStale {
                Image(systemName: "wifi.exclamationmark")
                    .foregroundStyle(.secondary)
                    .help("Données issues du cache : l'unité n'a pas répondu en direct.")
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        guard device.state.power == .on else { return "Éteint" }
        guard let inside = device.state.insideTemperature else { return device.state.mode.label }
        return "\(device.state.mode.label) · \(Int(inside.rounded())) °C"
    }
}
