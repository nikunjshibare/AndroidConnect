import SwiftUI

/// Settings view for AndroidConnect.
/// Provides manual IP fallback, Bluetooth device picker, OTP toggle,
/// clipboard sync toggle, and Launch at Login toggle.
struct SettingsView: View {

    @Bindable var viewModel: BridgeViewModel

    var body: some View {
        TabView {
            connectionSettingsTab
                .tabItem {
                    Label("Connection", systemImage: "network")
                }

            bluetoothSettingsTab
                .tabItem {
                    Label("Bluetooth", systemImage: "wave.3.right")
                }

            notificationSettingsTab
                .tabItem {
                    Label("Notifications", systemImage: "bell.badge")
                }

            generalSettingsTab
                .tabItem {
                    Label("General", systemImage: "gear")
                }
        }
        .frame(minWidth: 320, minHeight: 320)
    }

    // MARK: - Connection Settings

    private var connectionSettingsTab: some View {
        Form {
            Section("Manual Connection Fallback") {
                TextField("IP Address", text: Binding(
                    get: { viewModel.manualHost },
                    set: { viewModel.manualHost = $0 }
                ))
                .textFieldStyle(.roundedBorder)

                TextField("Port", text: Binding(
                    get: { viewModel.manualPort },
                    set: { viewModel.manualPort = $0 }
                ))
                .textFieldStyle(.roundedBorder)

                HStack {
                    Circle()
                        .fill(viewModel.isConnected ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(viewModel.connectionStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if viewModel.isConnected {
                        Button("Disconnect") { viewModel.disconnect() }
                            .buttonStyle(.bordered)
                    } else {
                        Button("Connect") { viewModel.connectManually() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }

            Section("Auto-Discovery (Bonjour)") {
                HStack {
                    Text(viewModel.mdnsBrowser.isBrowsing ? "Scanning..." : "Not scanning")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if viewModel.mdnsBrowser.isBrowsing {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if viewModel.mdnsBrowser.discoveredEndpoints.isEmpty {
                    Text("No devices found on local network.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(viewModel.mdnsBrowser.discoveredEndpoints) { endpoint in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(endpoint.name)
                                    .font(.body)
                                Text("\(endpoint.host):\(endpoint.port)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Connect") {
                                viewModel.connectToDiscovered(endpoint)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Bluetooth Settings

    private var bluetoothSettingsTab: some View {
        Form {
            Section("Bluetooth Audio Device") {
                if viewModel.bluetoothAudio.isPaired,
                   let name = viewModel.bluetoothAudio.pairedDeviceName {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Paired: \(name)")
                    }
                } else {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("No Bluetooth device selected")
                    }
                }

                Button("Refresh Devices") {
                    viewModel.bluetoothAudio.refreshDevices()
                }
                .buttonStyle(.bordered)
            }

            Section("Available Devices") {
                if viewModel.bluetoothAudio.availableDevices.isEmpty {
                    Text("No paired Bluetooth devices found.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(viewModel.bluetoothAudio.availableDevices) { device in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(device.name)
                                    .font(.body)
                                Text(device.isConnected ? "Connected" : "Not connected")
                                    .font(.caption)
                                    .foregroundStyle(device.isConnected ? .green : .secondary)
                            }
                            Spacer()
                            Button("Select") {
                                Task {
                                    try? await viewModel.bluetoothAudio.selectDevice(address: device.id)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Notification Settings

    private var notificationSettingsTab: some View {
        Form {
            Section("OTP Auto-Copy") {
                Toggle("Automatically copy OTP codes to clipboard",
                       isOn: Binding(
                        get: { viewModel.notificationBridge.isOTPAutoCopyEnabled },
                        set: { viewModel.notificationBridge.isOTPAutoCopyEnabled = $0 }
                       ))

                Text("When enabled, OTP codes received from your phone are automatically copied to the macOS clipboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Clipboard Sync") {
                Toggle("Sync clipboard between Mac and phone",
                       isOn: Binding(
                        get: { viewModel.clipboardSync.isSyncEnabled },
                        set: { viewModel.clipboardSync.isSyncEnabled = $0 }
                       ))

                Text("Text copied on either device will be available on the other.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - General Settings

    private var generalSettingsTab: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { viewModel.launchAtLogin },
                    set: { viewModel.launchAtLogin = $0 }
                ))

                Text("AndroidConnect will start automatically when you log in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("App", value: "AndroidConnect")
                LabeledContent("Target Device", value: "Motorola Moto G52")
                LabeledContent("Protocol", value: "WebSocket (Port 8989)")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
