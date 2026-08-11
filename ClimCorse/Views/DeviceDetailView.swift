import SwiftUI

struct DeviceDetailView: View {
    @EnvironmentObject private var viewModel: ClimateViewModel
    let device: ClimateDevice

    /// Plage de consigne des unités résidentielles Panasonic.
    private let temperatureRange: ClosedRange<Double> = 16...30

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                Divider()
                temperatureSection
                Divider()
                modeSection
                Divider()
                airflowSection
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .navigationTitle(device.info.name)
    }

    // MARK: - En-tête

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(device.info.group)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    if let inside = device.state.insideTemperature {
                        readout(label: "Intérieur", value: inside)
                    }
                    if let outside = device.state.outsideTemperature {
                        readout(label: "Extérieur", value: outside)
                    }
                }

                if device.isStale {
                    Label("Données en cache — unité injoignable en direct",
                          systemImage: "wifi.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Toggle("Marche", isOn: Binding(
                get: { device.state.power == .on },
                set: { _ in viewModel.togglePower(device) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
    }

    private func readout(label: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(value, specifier: "%.1f") °C")
                .font(.title2)
                .monospacedDigit()
        }
    }

    // MARK: - Consigne

    private var temperatureSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Consigne").font(.headline)
                Spacer()
                Text(target.map { String(format: "%.1f °C", $0) } ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: Binding(
                    get: { target ?? 21 },
                    set: { viewModel.setTargetTemperature(($0 * 2).rounded() / 2, on: device) }
                ),
                in: temperatureRange,
                step: 0.5
            )
            // En ventilation seule, la consigne n'a pas de sens.
            .disabled(device.state.mode == .fan)
        }
    }

    private var target: Double? { device.state.targetTemperature }

    // MARK: - Mode

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mode").font(.headline)
            Picker("Mode", selection: Binding(
                get: { device.state.mode },
                set: { viewModel.setMode($0, on: device) }
            )) {
                ForEach(device.info.availableModes, id: \.self) { mode in
                    Label(mode.label, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // MARK: - Soufflage

    private var airflowSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Soufflage").font(.headline)

            Picker("Ventilation", selection: Binding(
                get: { device.state.fanSpeed },
                set: { viewModel.setFanSpeed($0, on: device) }
            )) {
                ForEach(FanSpeed.allCases, id: \.self) { Text($0.label).tag($0) }
            }

            Picker("Oscillation verticale", selection: Binding(
                get: { device.state.verticalSwing },
                set: { viewModel.setVerticalSwing($0, on: device) }
            )) {
                ForEach(AirSwingUD.allCases, id: \.self) { Text($0.label).tag($0) }
            }

            if device.info.supportsHorizontalSwing {
                Picker("Oscillation horizontale", selection: Binding(
                    get: { device.state.horizontalSwing },
                    set: { viewModel.setHorizontalSwing($0, on: device) }
                )) {
                    ForEach(AirSwingLR.allCases.filter { $0 != .unavailable }, id: \.self) {
                        Text($0.label).tag($0)
                    }
                }
            }
        }
    }
}
