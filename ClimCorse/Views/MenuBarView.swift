import SwiftUI

/// Panneau de la barre de menus : les gestes fréquents, sans ouvrir la fenêtre.
struct MenuBarView: View {
    @EnvironmentObject private var viewModel: ClimateViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if viewModel.isAuthenticated {
                if viewModel.devices.isEmpty {
                    Text("Aucun climatiseur")
                        .foregroundStyle(.secondary)
                        .padding(12)
                } else {
                    ForEach(viewModel.devices) { device in
                        MenuBarDeviceRow(device: device)
                        if device.id != viewModel.devices.last?.id {
                            Divider().padding(.horizontal, 12)
                        }
                    }
                }
            } else {
                Text("Connectez-vous à votre compte Panasonic")
                    .foregroundStyle(.secondary)
                    .padding(12)
            }

            Divider()
            footer
        }
        .frame(width: 300)
    }

    private var footer: some View {
        HStack {
            Button {
                Task { await viewModel.refresh() }
            } label: {
                Label("Actualiser", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isLoading || !viewModel.isAuthenticated)

            Spacer()

            if let lastRefresh = viewModel.lastRefresh {
                Text(lastRefresh, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quitter", systemImage: "power")
            }
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .padding(10)
    }
}

private struct MenuBarDeviceRow: View {
    @EnvironmentObject private var viewModel: ClimateViewModel
    let device: ClimateDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.info.name).fontWeight(.medium)
                    if let inside = device.state.insideTemperature {
                        Text("\(inside, specifier: "%.1f") °C")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { device.state.power == .on },
                    set: { _ in viewModel.togglePower(device) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }

            if device.state.power == .on {
                Picker("", selection: Binding(
                    get: { device.state.mode },
                    set: { viewModel.setMode($0, on: device) }
                )) {
                    ForEach(device.info.availableModes, id: \.self) {
                        Image(systemName: $0.symbol).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack {
                    Text(device.state.targetTemperature.map { String(format: "%.1f °C", $0) } ?? "—")
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 52, alignment: .leading)

                    Slider(
                        value: Binding(
                            get: { device.state.targetTemperature ?? 21 },
                            set: { viewModel.setTargetTemperature(($0 * 2).rounded() / 2, on: device) }
                        ),
                        in: 16...30,
                        step: 0.5
                    )
                    .disabled(device.state.mode == .fan)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
