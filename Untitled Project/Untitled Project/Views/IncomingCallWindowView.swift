import SwiftUI
import AppKit

/// A floating, non-activating HUD panel for incoming and active calls.
/// Uses NSPanel to stay on top without stealing focus from other apps.
struct IncomingCallWindowView: View {

    @Bindable var viewModel: BridgeViewModel

    var body: some View {
        if let call = viewModel.activeCall {
            VStack(spacing: 16) {
                // Call Direction Icon
                Image(systemName: call.direction == .incoming ? "phone.arrow.down.left" : "phone.arrow.up.right")
                    .font(.system(size: 40))
                    .foregroundStyle(callStatusColor(call.status))
                    .symbolEffect(.pulse, isActive: call.status == .ringing)

                // Contact Info
                VStack(spacing: 4) {
                    if let name = call.contactName {
                        Text(name)
                            .font(.title2.bold())
                    }
                    Text(call.phoneNumber)
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                // Status
                HStack(spacing: 6) {
                    Circle()
                        .fill(callStatusColor(call.status))
                        .frame(width: 8, height: 8)
                    Text(callStatusText(call))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Duration (for active calls)
                if call.status == .active {
                    Text(viewModel.formattedCallDuration)
                        .font(.title.monospacedDigit())
                        .foregroundStyle(.primary)
                }

                // Action Buttons
                callActionButtons(for: call)
            }
            .padding(24)
            .frame(width: 280)
            .background(.ultraThickMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private func callActionButtons(for call: CallStatePayload) -> some View {
        switch call.status {
        case .ringing where call.direction == .incoming:
            HStack(spacing: 20) {
                // Reject
                Button(action: { Task { await viewModel.rejectCall() } }) {
                    VStack(spacing: 4) {
                        Image(systemName: "phone.down.fill")
                            .font(.title2)
                            .padding(16)
                            .background(Color.red)
                            .clipShape(Circle())
                            .foregroundStyle(.white)
                        Text("Decline")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)

                // Answer
                Button(action: { Task { await viewModel.answerCall() } }) {
                    VStack(spacing: 4) {
                        Image(systemName: "phone.fill")
                            .font(.title2)
                            .padding(16)
                            .background(Color.green)
                            .clipShape(Circle())
                            .foregroundStyle(.white)
                        Text("Answer")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
            }

        case .active, .held:
            HStack(spacing: 16) {
                // Hold/Resume
                Button(action: { Task { await viewModel.holdCall() } }) {
                    VStack(spacing: 4) {
                        Image(systemName: call.status == .held ? "play.fill" : "pause.fill")
                            .font(.title3)
                            .padding(12)
                            .background(Color.orange.opacity(0.2))
                            .clipShape(Circle())
                        Text(call.status == .held ? "Resume" : "Hold")
                            .font(.caption2)
                    }
                }
                .buttonStyle(.plain)

                // Bluetooth Audio
                if viewModel.bluetoothAudio.isPaired {
                    Button(action: {
                        Task {
                            if viewModel.bluetoothAudio.isAudioConnected {
                                viewModel.bluetoothAudio.disconnectAudio()
                            } else {
                                try? await viewModel.bluetoothAudio.connectAudio()
                            }
                        }
                    }) {
                        VStack(spacing: 4) {
                            Image(systemName: viewModel.bluetoothAudio.isAudioConnected
                                  ? "headphones" : "headphones.circle")
                                .font(.title3)
                                .padding(12)
                                .background(Color.blue.opacity(0.2))
                                .clipShape(Circle())
                            Text("Audio")
                                .font(.caption2)
                        }
                    }
                    .buttonStyle(.plain)
                }

                // Hang Up
                Button(action: { Task { await viewModel.hangupCall() } }) {
                    VStack(spacing: 4) {
                        Image(systemName: "phone.down.fill")
                            .font(.title3)
                            .padding(12)
                            .background(Color.red)
                            .clipShape(Circle())
                            .foregroundStyle(.white)
                        Text("End")
                            .font(.caption2)
                    }
                }
                .buttonStyle(.plain)
            }

        case .ended:
            Text("Call Ended")
                .font(.subheadline)
                .foregroundStyle(.secondary)

        default:
            EmptyView()
        }
    }

    // MARK: - Helpers

    private func callStatusColor(_ status: CallStatus) -> Color {
        switch status {
        case .ringing: return .orange
        case .active: return .green
        case .held: return .yellow
        case .ended: return .gray
        }
    }

    private func callStatusText(_ call: CallStatePayload) -> String {
        switch call.status {
        case .ringing:
            return call.direction == .incoming ? "Incoming Call" : "Calling..."
        case .active:
            return "In Call"
        case .held:
            return "On Hold"
        case .ended:
            return "Call Ended"
        }
    }
}

// MARK: - NSPanel Controller for Floating Call Window

/// Creates and manages a floating non-activating NSPanel for call HUD display.
final class CallWindowController: NSObject {

    private var panel: NSPanel?
    private var hostingView: NSHostingView<IncomingCallWindowView>?

    @MainActor
    func showCallWindow(viewModel: BridgeViewModel) {
        guard panel == nil else { return }

        let callView = IncomingCallWindowView(viewModel: viewModel)
        let hosting = NSHostingView(rootView: callView)
        hostingView = hosting

        let panelRect = NSRect(x: 0, y: 0, width: 300, height: 320)
        let newPanel = NSPanel(
            contentRect: panelRect,
            styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        newPanel.isFloatingPanel = true
        newPanel.level = .floating
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.titlebarAppearsTransparent = true
        newPanel.titleVisibility = .hidden
        newPanel.isMovableByWindowBackground = true
        newPanel.backgroundColor = .clear
        newPanel.contentView = hosting
        newPanel.isReleasedWhenClosed = false

        // Position at top-right of screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - panelRect.width - 20
            let y = screenFrame.maxY - panelRect.height - 20
            newPanel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        newPanel.orderFrontRegardless()
        panel = newPanel
    }

    @MainActor
    func dismissCallWindow() {
        panel?.close()
        panel = nil
        hostingView = nil
    }

    @MainActor
    var isVisible: Bool {
        panel?.isVisible ?? false
    }
}
