import SwiftUI
import AppKit

/// AndroidConnect — macOS menu bar app for bridging with Android phone.
@main
struct MyApp: App {

    @State private var viewModel = BridgeViewModel()
    @State private var callWindowController = CallWindowController()
    @State private var hasSetUp = false

    var body: some Scene {
        // Menu Bar Extra — the primary UI
        MenuBarExtra {
            MenuBarPopoverView(viewModel: viewModel)
                .task {
                    guard !hasSetUp else { return }
                    hasSetUp = true
                    await viewModel.setup()
                    startCallWindowObserver()
                }
        } label: {
            Label {
                Text("AndroidConnect")
            } icon: {
                Image(systemName: menuBarIcon)
            }
        }
        .menuBarExtraStyle(.window)

        // Settings Window
        Settings {
            SettingsView(viewModel: viewModel)
        }
    }

    /// Dynamic menu bar icon based on connection state.
    private var menuBarIcon: String {
        switch viewModel.webSocket.connectionState {
        case .connected:
            return "iphone.and.arrow.forward"
        case .connecting, .reconnecting:
            return "iphone.radiowaves.left.and.right"
        case .disconnected:
            return "iphone.slash"
        }
    }

    @MainActor
    private func startCallWindowObserver() {
        // Poll for call window state changes using a task
        Task {
            var lastShowState = false
            while true {
                try? await Task.sleep(for: .milliseconds(250))
                let shouldShow = viewModel.showIncomingCallWindow
                if shouldShow != lastShowState {
                    lastShowState = shouldShow
                    if shouldShow {
                        callWindowController.showCallWindow(viewModel: viewModel)
                    } else {
                        callWindowController.dismissCallWindow()
                    }
                }
            }
        }
    }
}
