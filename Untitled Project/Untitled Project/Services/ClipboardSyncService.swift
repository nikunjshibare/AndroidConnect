import Foundation
import AppKit

/// Monitors the macOS pasteboard for changes and synchronizes clipboard text
/// with the connected Android device.
@MainActor
@Observable
final class ClipboardSyncService {

    // MARK: - Configuration

    var isSyncEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(isSyncEnabled, forKey: "clipboardSyncEnabled")
            if isSyncEnabled {
                startMonitoring()
            } else {
                stopMonitoring()
            }
        }
    }

    // MARK: - State

    private(set) var lastSyncedText: String? = nil
    private(set) var isMonitoring: Bool = false

    // MARK: - Callbacks

    /// Called when new clipboard content is detected locally that should
    /// be pushed to Android.
    var onLocalClipboardChange: ((String) -> Void)?

    // MARK: - Private

    private var monitorTask: Task<Void, Never>?
    private var lastChangeCount: Int = 0
    private var ignoreNextChange = false

    // MARK: - Lifecycle

    init() {
        if UserDefaults.standard.object(forKey: "clipboardSyncEnabled") != nil {
            isSyncEnabled = UserDefaults.standard.bool(forKey: "clipboardSyncEnabled")
        }
    }

    // MARK: - Monitoring

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        lastChangeCount = NSPasteboard.general.changeCount

        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.checkForChanges()
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        isMonitoring = false
    }

    /// Called when receiving clipboard content from Android.
    func receiveFromAndroid(_ text: String) {
        // Set flag to ignore the pasteboard change we're about to cause
        ignoreNextChange = true
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        lastSyncedText = text
        lastChangeCount = NSPasteboard.general.changeCount
    }

    // MARK: - Private

    private func checkForChanges() {
        let currentCount = NSPasteboard.general.changeCount

        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        if ignoreNextChange {
            ignoreNextChange = false
            return
        }

        guard isSyncEnabled else { return }

        guard let text = NSPasteboard.general.string(forType: .string),
              !text.isEmpty,
              text != lastSyncedText else { return }

        lastSyncedText = text
        onLocalClipboardChange?(text)
    }
}
