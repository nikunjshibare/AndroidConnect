import SwiftUI

/// Main menu bar popover showing connection status, phone telemetry,
/// recent notifications, dialer, settings, and quick actions.
struct MenuBarPopoverView: View {

    @Bindable var viewModel: BridgeViewModel
    @State private var selectedTab: Tab = .dashboard
    @State private var showingSettings: Bool = false

    enum Tab: String, CaseIterable {
        case dashboard = "Dashboard"
        case notifications = "Notifications"
        case dialer = "Dialer"
    }

    var body: some View {
        Group {
            if showingSettings {
                settingsContainerView
            } else {
                mainPopoverContent
            }
        }
        .frame(width: 320)
    }

    // MARK: - Main Popover View

    private var mainPopoverContent: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // Tab Picker
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Content
            ScrollView {
                switch selectedTab {
                case .dashboard:
                    dashboardView
                case .notifications:
                    notificationsView
                case .dialer:
                    dialerView
                }
            }
            .frame(maxHeight: 350)

            Divider()

            // Footer Actions
            footerView
        }
    }

    // MARK: - Settings Container View (Embedded inside Popover)

    private var settingsContainerView: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: { showingSettings = false }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(.body)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)

                Spacer()

                Text("Settings")
                    .font(.headline)

                Spacer()

                // Balance with transparent spacer
                Color.clear.frame(width: 50, height: 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            SettingsView(viewModel: viewModel)
                .frame(maxHeight: 360)

            Divider()

            HStack {
                Spacer()
                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    Label("Quit App", systemImage: "power")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Circle()
                .fill(viewModel.isConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)

            Text(viewModel.connectionStatus)
                .font(.headline)

            Spacer()

            if viewModel.isConnected {
                HStack(spacing: 8) {
                    // Battery
                    Label {
                        Text("\(viewModel.phoneBattery)%")
                            .font(.caption)
                    } icon: {
                        Image(systemName: viewModel.batteryIcon)
                            .font(.caption)
                    }

                    // Signal
                    Image(systemName: viewModel.signalIcon)
                        .font(.caption)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Dashboard

    private var dashboardView: some View {
        VStack(spacing: 12) {
            if viewModel.isConnected {
                connectedDashboardView
            } else {
                disconnectedDashboardView
            }
        }
        .padding(12)
    }

    // MARK: - Connected Dashboard

    private var connectedDashboardView: some View {
        VStack(spacing: 12) {
            // Telemetry Card
            GroupBox("Phone Status") {
                VStack(alignment: .leading, spacing: 6) {
                    telemetryRow(icon: viewModel.batteryIcon,
                                 label: "Battery",
                                 value: "\(viewModel.phoneBattery)%\(viewModel.phoneIsCharging ? " ⚡" : "")")

                    telemetryRow(icon: viewModel.signalIcon,
                                 label: "Network",
                                 value: viewModel.phoneNetworkType)

                    telemetryRow(icon: "internaldrive",
                                 label: "Storage Free",
                                 value: formatStorage(viewModel.phoneStorageFreeMB))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Active Call Card
            if let call = viewModel.activeCall, call.status != .ended {
                GroupBox("Active Call") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "phone.fill")
                                .foregroundStyle(.green)
                            Text(call.contactName ?? call.phoneNumber)
                                .font(.headline)
                        }

                        Text(call.status.rawValue.capitalized)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if call.status == .active {
                            Text(viewModel.formattedCallDuration)
                                .font(.caption.monospacedDigit())
                        }

                        HStack(spacing: 12) {
                            if call.status == .ringing && call.direction == .incoming {
                                Button(action: { Task { await viewModel.answerCall() } }) {
                                    Label("Answer", systemImage: "phone.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.green)

                                Button(action: { Task { await viewModel.rejectCall() } }) {
                                    Label("Reject", systemImage: "phone.down.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                            } else if call.status == .active || call.status == .held {
                                Button(action: { Task { await viewModel.holdCall() } }) {
                                    Label(call.status == .held ? "Resume" : "Hold",
                                          systemImage: "pause.fill")
                                }
                                .buttonStyle(.bordered)

                                Button(action: { Task { await viewModel.hangupCall() } }) {
                                    Label("Hang Up", systemImage: "phone.down.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // Quick Actions
            GroupBox("Quick Actions") {
                HStack(spacing: 12) {
                    Button(action: { Task { await viewModel.ringPhone() } }) {
                        VStack {
                            Image(systemName: "bell.fill")
                                .font(.title3)
                            Text("Find Phone")
                                .font(.caption2)
                        }
                    }
                    .buttonStyle(.bordered)

                    Toggle(isOn: Binding(
                        get: { viewModel.clipboardSync.isSyncEnabled },
                        set: { viewModel.clipboardSync.isSyncEnabled = $0 }
                    )) {
                        VStack {
                            Image(systemName: "doc.on.clipboard")
                                .font(.title3)
                            Text("Clipboard")
                                .font(.caption2)
                        }
                    }
                    .toggleStyle(.button)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Disconnected Dashboard

    private var disconnectedDashboardView: some View {
        VStack(spacing: 12) {
            GroupBox {
                VStack(spacing: 12) {
                    HStack(spacing: 10) {
                        if viewModel.mdnsBrowser.isBrowsing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(viewModel.mdnsBrowser.isBrowsing
                                 ? "Searching for AndroidConnect on Wi-Fi..."
                                 : "Wi-Fi scan paused")
                                .font(.subheadline.bold())

                            Text("Ensure the companion app is running on your phone.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    HStack(spacing: 8) {
                        Button(action: {
                            viewModel.mdnsBrowser.restartBrowsing()
                        }) {
                            Label("Retry Scan", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button(action: {
                            showingSettings = true
                        }) {
                            Label("Connect Manually", systemImage: "slider.horizontal.3")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(4)
            } label: {
                Label("Status", systemImage: "wifi.slash")
            }

            // Discovered devices list if any
            if !viewModel.mdnsBrowser.discoveredEndpoints.isEmpty {
                GroupBox("Discovered Devices") {
                    VStack(spacing: 6) {
                        ForEach(viewModel.mdnsBrowser.discoveredEndpoints) { endpoint in
                            Button(action: { viewModel.connectToDiscovered(endpoint) }) {
                                HStack {
                                    Image(systemName: "iphone")
                                    VStack(alignment: .leading) {
                                        Text(endpoint.name)
                                            .font(.body)
                                        Text("\(endpoint.host):\(endpoint.port)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Notifications

    private var notificationsView: some View {
        VStack(spacing: 8) {
            if viewModel.notificationBridge.recentNotifications.isEmpty {
                ContentUnavailableView {
                    Label("No Notifications", systemImage: "bell.slash")
                } description: {
                    Text("Notifications from your phone will appear here.")
                }
                .padding(.vertical, 20)
            } else {
                ForEach(viewModel.notificationBridge.recentNotifications) { notif in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: notif.isOTP ? "lock.shield" : "app.badge")
                            .font(.title3)
                            .foregroundStyle(notif.isOTP ? .orange : .blue)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(notif.appName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(notif.receivedAt, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }

                            Text(notif.title)
                                .font(.subheadline.bold())
                                .lineLimit(1)

                            Text(notif.body)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)

                            if let otp = notif.otpCode {
                                Button(action: {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(otp, forType: .string)
                                }) {
                                    Label("Copy OTP: \(otp)", systemImage: "doc.on.doc")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    if notif.id != viewModel.notificationBridge.recentNotifications.last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(12)
    }

    // MARK: - Dialer

    private var dialerView: some View {
        VStack(spacing: 16) {
            // Number input
            HStack {
                TextField("Phone number", text: $viewModel.dialerNumber)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3.monospacedDigit())

                Button(action: { Task { await viewModel.dialNumber() } }) {
                    Image(systemName: "phone.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(viewModel.dialerNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .disabled(!viewModel.isConnected)
            }

            // Dial pad
            let keys: [[String]] = [
                ["1", "2", "3"],
                ["4", "5", "6"],
                ["7", "8", "9"],
                ["*", "0", "#"]
            ]

            ForEach(keys, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { key in
                        Button(action: { viewModel.dialerNumber.append(key) }) {
                            Text(key)
                                .font(.title2.monospacedDigit())
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            // Backspace
            HStack {
                Spacer()
                Button(action: {
                    if !viewModel.dialerNumber.isEmpty {
                        viewModel.dialerNumber.removeLast()
                    }
                }) {
                    Image(systemName: "delete.left")
                        .font(.title3)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.dialerNumber.isEmpty)
            }
        }
        .padding(12)
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            if viewModel.isConnected {
                Button("Disconnect") {
                    viewModel.disconnect()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Spacer()

            if let error = viewModel.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .frame(maxWidth: 150)
            }

            Spacer()

            Button(action: {
                showingSettings = true
            }) {
                Image(systemName: "gear")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                Image(systemName: "power")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func telemetryRow(icon: String, label: String, value: String) -> some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.bold())
        }
    }

    private func formatStorage(_ mb: Int) -> String {
        if mb > 1024 {
            return String(format: "%.1f GB", Double(mb) / 1024.0)
        }
        return "\(mb) MB"
    }
}
