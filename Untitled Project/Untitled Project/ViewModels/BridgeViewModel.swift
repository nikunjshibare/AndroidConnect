import Foundation
import AppKit

/// Central state store driving the entire AndroidConnect UI.
/// Coordinates all services and handles WebSocket message routing.
@MainActor
@Observable
final class BridgeViewModel: PhoneWebSocketClientDelegate {

    // MARK: - Services

    let mdnsBrowser = MDNSBrowserService()
    let webSocket = PhoneWebSocketClient()
    let notificationBridge = NotificationBridgeService()
    let bluetoothAudio = BluetoothCallAudioService()
    let clipboardSync = ClipboardSyncService()

    // MARK: - Connection State

    var connectionStatus: String {
        switch webSocket.connectionState {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting..."
        case .connected:
            return "Connected"
        case .reconnecting(let attempt):
            return "Reconnecting (\(attempt))..."
        }
    }

    var isConnected: Bool {
        webSocket.connectionState == .connected
    }

    // MARK: - Telemetry

    private(set) var phoneBattery: Int = 0
    private(set) var phoneIsCharging: Bool = false
    private(set) var phoneSignalStrength: Int = 0
    private(set) var phoneNetworkType: String = ""
    private(set) var phoneStorageFreeMB: Int = 0

    // MARK: - Call State

    private(set) var activeCall: CallStatePayload? = nil
    private(set) var callDurationTimer: Task<Void, Never>? = nil
    private(set) var callDurationSeconds: Int = 0
    var showIncomingCallWindow: Bool = false

    // MARK: - Settings

    var manualHost: String {
        get { UserDefaults.standard.string(forKey: "manualHost") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "manualHost") }
    }

    var manualPort: String {
        get { UserDefaults.standard.string(forKey: "manualPort") ?? "8989" }
        set { UserDefaults.standard.set(newValue, forKey: "manualPort") }
    }

    var launchAtLogin: Bool {
        get { UserDefaults.standard.bool(forKey: "launchAtLogin") }
        set { UserDefaults.standard.set(newValue, forKey: "launchAtLogin") }
    }

    // MARK: - Dialer

    var dialerNumber: String = ""

    // MARK: - Error Handling

    private(set) var lastError: String? = nil

    // MARK: - Setup

    func setup() async {
        // Request notification permissions
        await notificationBridge.requestAuthorization()

        // Set up WebSocket delegate
        webSocket.delegate = self

        // Set up notification reply callback
        notificationBridge.onReply = { [weak self] notificationId, replyText in
            Task { @MainActor [weak self] in
                await self?.sendNotificationReply(notificationId: notificationId, text: replyText)
            }
        }

        // Set up clipboard sync callback
        clipboardSync.onLocalClipboardChange = { [weak self] text in
            Task { @MainActor [weak self] in
                await self?.sendClipboard(text: text)
            }
        }

        // Start Bonjour discovery
        mdnsBrowser.startBrowsing()
    }

    // MARK: - Connection Actions

    func connectToDiscovered(_ endpoint: MDNSBrowserService.DiscoveredEndpoint) {
        webSocket.connect(host: endpoint.host, port: endpoint.port)
    }

    func connectManually() {
        let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            lastError = "Please enter a host address"
            return
        }

        let port = UInt16(manualPort) ?? 8989
        webSocket.connect(host: host, port: port)
    }

    func disconnect() {
        webSocket.disconnect()
        resetTelemetry()
    }

    // MARK: - Call Actions

    func answerCall() async {
        guard let call = activeCall else { return }
        let payload = CallActionPayload(callId: call.callId, action: .answer, phoneNumber: nil)
        await sendMessage(type: .callAction, payload: .callAction(payload))
    }

    func rejectCall() async {
        guard let call = activeCall else { return }
        let payload = CallActionPayload(callId: call.callId, action: .reject, phoneNumber: nil)
        await sendMessage(type: .callAction, payload: .callAction(payload))
    }

    func hangupCall() async {
        guard let call = activeCall else { return }
        let payload = CallActionPayload(callId: call.callId, action: .hangup, phoneNumber: nil)
        await sendMessage(type: .callAction, payload: .callAction(payload))
    }

    func holdCall() async {
        guard let call = activeCall else { return }
        let action: CallActionCommand = call.status == .held ? .unhold : .hold
        let payload = CallActionPayload(callId: call.callId, action: action, phoneNumber: nil)
        await sendMessage(type: .callAction, payload: .callAction(payload))
    }

    func dialNumber() async {
        let number = dialerNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !number.isEmpty else { return }

        let payload = CallActionPayload(callId: nil, action: .dial, phoneNumber: number)
        await sendMessage(type: .callAction, payload: .callAction(payload))
        dialerNumber = ""
    }

    // MARK: - Ring Phone (Find My Phone)

    func ringPhone() async {
        let payload = RingPhonePayload(durationSeconds: 10)
        await sendMessage(type: .ringPhone, payload: .ringPhone(payload))
    }

    // MARK: - Private Helpers

    private func sendNotificationReply(notificationId: String, text: String) async {
        let payload = NotificationReplyPayload(notificationId: notificationId, replyText: text)
        await sendMessage(type: .notificationReply, payload: .notificationReply(payload))
    }

    private func sendClipboard(text: String) async {
        let payload = ClipboardPayload(text: text, source: .mac)
        await sendMessage(type: .clipboard, payload: .clipboard(payload))
    }

    private func sendMessage(type: BridgeMessageType, payload: BridgePayload) async {
        do {
            try await webSocket.send(type: type, payload: payload)
            lastError = nil
        } catch {
            lastError = "Send failed: \(error.localizedDescription)"
            print("[BridgeVM] Send error: \(error)")
        }
    }

    private func resetTelemetry() {
        phoneBattery = 0
        phoneIsCharging = false
        phoneSignalStrength = 0
        phoneNetworkType = ""
        phoneStorageFreeMB = 0
        activeCall = nil
        callDurationTimer?.cancel()
        callDurationTimer = nil
        callDurationSeconds = 0
        showIncomingCallWindow = false
    }

    // MARK: - Call Duration Timer

    private func startCallTimer() {
        callDurationSeconds = 0
        callDurationTimer?.cancel()
        callDurationTimer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                callDurationSeconds += 1
            }
        }
    }

    private func stopCallTimer() {
        callDurationTimer?.cancel()
        callDurationTimer = nil
        callDurationSeconds = 0
    }

    // MARK: - PhoneWebSocketClientDelegate

    func webSocketDidConnect() {
        lastError = nil
        print("[BridgeVM] Connected to phone")
    }

    func webSocketDidDisconnect(error: Error?) {
        if let error {
            lastError = "Disconnected: \(error.localizedDescription)"
        }
        print("[BridgeVM] Disconnected: \(error?.localizedDescription ?? "clean")")
    }

    func webSocketDidReceive(envelope: BridgeEnvelope) {
        switch envelope.payload {
        case .telemetry(let t):
            phoneBattery = t.batteryPercent
            phoneIsCharging = t.isCharging
            phoneSignalStrength = t.signalStrength
            phoneNetworkType = t.networkType
            phoneStorageFreeMB = t.storageFreeMB

        case .notification(let n):
            Task {
                await notificationBridge.postNotification(from: n)
            }

        case .callState(let c):
            handleCallState(c)

        case .clipboard(let clip):
            if clip.source == .android {
                clipboardSync.receiveFromAndroid(clip.text)
            }

        case .notificationReply, .callAction, .ringPhone, .ping, .pong:
            // These are outbound-only or already handled
            break
        }
    }

    private func handleCallState(_ call: CallStatePayload) {
        activeCall = call

        switch call.status {
        case .ringing:
            if call.direction == .incoming {
                showIncomingCallWindow = true
            }
            stopCallTimer()

        case .active:
            showIncomingCallWindow = true  // Show active call HUD
            startCallTimer()

        case .held:
            // Keep the window visible
            break

        case .ended:
            stopCallTimer()
            // Dismiss call window after a brief delay
            Task {
                try? await Task.sleep(for: .seconds(2))
                showIncomingCallWindow = false
                activeCall = nil
            }
        }
    }

    // MARK: - Utility

    var batteryIcon: String {
        if phoneIsCharging { return "battery.100.bolt" }
        switch phoneBattery {
        case 0..<20: return "battery.25"
        case 20..<50: return "battery.50"
        case 50..<80: return "battery.75"
        default: return "battery.100"
        }
    }

    var signalIcon: String {
        switch phoneSignalStrength {
        case 0: return "wifi.slash"
        case 1: return "cellularbars"
        case 2: return "cellularbars"
        case 3: return "cellularbars"
        default: return "cellularbars"
        }
    }

    var formattedCallDuration: String {
        let minutes = callDurationSeconds / 60
        let seconds = callDurationSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
