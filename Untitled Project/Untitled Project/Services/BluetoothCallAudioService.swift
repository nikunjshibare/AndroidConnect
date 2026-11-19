import Foundation
import IOBluetooth

// MARK: - Protocol for Bluetooth Call Audio

/// Protocol abstracting Bluetooth Hands-Free audio so the app compiles and
/// degrades gracefully when no Bluetooth device is paired.
@MainActor
protocol BluetoothCallAudioProviding: AnyObject {
    var isPaired: Bool { get }
    var isAudioConnected: Bool { get }
    var pairedDeviceName: String? { get }
    func connectAudio() async throws
    func disconnectAudio()
    func selectDevice(address: String) async throws
}

// MARK: - IOBluetooth Implementation

/// Wraps IOBluetoothDevice for Hands-Free Profile (HFP) audio routing.
/// Falls back gracefully when Bluetooth is unavailable or no device is paired.
@MainActor
@Observable
final class BluetoothCallAudioService: BluetoothCallAudioProviding {

    // MARK: - State

    private(set) var isPaired: Bool = false
    private(set) var isAudioConnected: Bool = false
    private(set) var pairedDeviceName: String? = nil

    private(set) var availableDevices: [BluetoothDeviceInfo] = []

    // MARK: - Types

    struct BluetoothDeviceInfo: Identifiable, Equatable {
        let id: String          // MAC address
        let name: String
        let isConnected: Bool
    }

    // MARK: - Private

    private var selectedDeviceAddress: String?

    // MARK: - Setup

    init() {
        refreshDevices()

        // Load saved device preference
        if let saved = UserDefaults.standard.string(forKey: "bluetoothDeviceAddress") {
            selectedDeviceAddress = saved
            checkPairingStatus()
        }
    }

    // MARK: - Device Discovery

    func refreshDevices() {
        guard let paired = IOBluetoothDevice.pairedDevices() else {
            availableDevices = []
            return
        }

        availableDevices = paired.compactMap { device -> BluetoothDeviceInfo? in
            guard let btDevice = device as? IOBluetoothDevice,
                  let name = btDevice.name,
                  let address = btDevice.addressString else {
                return nil
            }
            return BluetoothDeviceInfo(
                id: address,
                name: name,
                isConnected: btDevice.isConnected()
            )
        }
    }

    // MARK: - BluetoothCallAudioProviding

    func selectDevice(address: String) async throws {
        selectedDeviceAddress = address
        UserDefaults.standard.set(address, forKey: "bluetoothDeviceAddress")
        checkPairingStatus()
    }

    func connectAudio() async throws {
        guard let address = selectedDeviceAddress,
              let device = IOBluetoothDevice(addressString: address) else {
            throw BluetoothError.noDeviceSelected
        }

        guard device.isPaired() else {
            isPaired = false
            throw BluetoothError.notPaired
        }

        let result = device.openConnection()
        if result != kIOReturnSuccess {
            throw BluetoothError.connectionFailed
        }

        isAudioConnected = true
    }

    func disconnectAudio() {
        guard let address = selectedDeviceAddress,
              let device = IOBluetoothDevice(addressString: address) else {
            return
        }

        device.closeConnection()
        isAudioConnected = false
    }

    // MARK: - Private

    private func checkPairingStatus() {
        guard let address = selectedDeviceAddress,
              let device = IOBluetoothDevice(addressString: address) else {
            isPaired = false
            pairedDeviceName = nil
            return
        }

        isPaired = device.isPaired()
        pairedDeviceName = device.name
    }

    // MARK: - Errors

    enum BluetoothError: LocalizedError {
        case noDeviceSelected
        case notPaired
        case connectionFailed

        var errorDescription: String? {
            switch self {
            case .noDeviceSelected:
                return "No Bluetooth device selected"
            case .notPaired:
                return "Selected device is not paired"
            case .connectionFailed:
                return "Failed to connect to Bluetooth device"
            }
        }
    }
}
