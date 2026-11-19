import Foundation

/// Delegate protocol for receiving WebSocket events.
@MainActor
protocol PhoneWebSocketClientDelegate: AnyObject {
    func webSocketDidConnect()
    func webSocketDidDisconnect(error: Error?)
    func webSocketDidReceive(envelope: BridgeEnvelope)
}

/// Persistent WebSocket client that connects to the Android companion app.
/// Supports auto-reconnect with exponential backoff and manual host:port fallback.
@MainActor
@Observable
final class PhoneWebSocketClient {

    // MARK: - State

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int)
    }

    private(set) var connectionState: ConnectionState = .disconnected

    weak var delegate: PhoneWebSocketClientDelegate?

    // MARK: - Configuration

    private var host: String = ""
    private var port: UInt16 = 8989
    private let maxReconnectAttempts = 10
    private let baseReconnectDelay: TimeInterval = 1.0
    private let maxReconnectDelay: TimeInterval = 60.0

    // MARK: - Private

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var reconnectAttempt = 0
    private var shouldReconnect = false
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?

    // MARK: - Public API

    /// Connect to a specific host and port.
    func connect(host: String, port: UInt16 = 8989) {
        self.host = host
        self.port = port
        shouldReconnect = true
        reconnectAttempt = 0
        establishConnection()
    }

    /// Gracefully disconnect and stop reconnecting.
    func disconnect() {
        shouldReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        pingTask?.cancel()
        pingTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        connectionState = .disconnected
    }

    /// Send a bridge envelope to the connected phone.
    func send(_ envelope: BridgeEnvelope) async throws {
        guard connectionState == .connected, let task = webSocketTask else {
            throw WebSocketError.notConnected
        }

        let data = try envelope.jsonData()
        try await task.send(.data(data))
    }

    /// Send a raw bridge payload with auto-envelope wrapping.
    func send(type: BridgeMessageType, payload: BridgePayload) async throws {
        let envelope = BridgeEnvelope.make(type, payload: payload)
        try await send(envelope)
    }

    // MARK: - Connection Management

    private func establishConnection() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        receiveTask?.cancel()
        pingTask?.cancel()

        connectionState = reconnectAttempt > 0
            ? .reconnecting(attempt: reconnectAttempt)
            : .connecting

        guard let url = URL(string: "ws://\(host):\(port)/bridge") else {
            print("[WebSocket] Invalid URL: ws://\(host):\(port)/bridge")
            return
        }

        let session = URLSession(configuration: .default)
        urlSession = session

        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 1_048_576 // 1 MB
        webSocketTask = task
        task.resume()

        // Start listening for messages
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        // Start keepalive pings
        pingTask = Task { [weak self] in
            await self?.pingLoop()
        }

        // Monitor the initial connection
        Task { [weak self] in
            // Give connection a moment to establish
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }

            // If we're still connecting after a reasonable timeout, try to send a ping
            // to verify the connection
            if self.connectionState == .connecting || self.connectionState != .connected {
                self.webSocketTask?.sendPing(pongReceiveHandler: { [weak self] error in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if let error {
                            print("[WebSocket] Connection ping failed: \(error)")
                            self.handleDisconnect(error: error)
                        } else {
                            self.connectionState = .connected
                            self.reconnectAttempt = 0
                            self.delegate?.webSocketDidConnect()
                        }
                    }
                })
            }
        }
    }

    private func receiveLoop() async {
        guard let task = webSocketTask else { return }

        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                await handleMessage(message)

                // If we successfully received a message, we're definitely connected
                if connectionState != .connected {
                    connectionState = .connected
                    reconnectAttempt = 0
                    delegate?.webSocketDidConnect()
                }
            } catch {
                if !Task.isCancelled {
                    handleDisconnect(error: error)
                }
                return
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) async {
        let data: Data

        switch message {
        case .data(let d):
            data = d
        case .string(let s):
            guard let d = s.data(using: .utf8) else { return }
            data = d
        @unknown default:
            return
        }

        do {
            let envelope = try BridgeEnvelope.decode(from: data)

            // Auto-respond to pings
            if envelope.type == .ping {
                let pong = BridgeEnvelope.make(.pong, payload: .pong)
                try? await send(pong)
                return
            }

            delegate?.webSocketDidReceive(envelope: envelope)
        } catch {
            print("[WebSocket] Failed to decode message: \(error)")
        }
    }

    private func pingLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(15))

                guard let task = webSocketTask, connectionState == .connected else { continue }

                let ping = BridgeEnvelope.make(.ping, payload: .ping)
                let data = try ping.jsonData()
                try await task.send(.data(data))
            } catch {
                if !Task.isCancelled {
                    print("[WebSocket] Ping failed: \(error)")
                }
            }
        }
    }

    // MARK: - Reconnection

    private func handleDisconnect(error: Error?) {
        guard connectionState != .disconnected else { return }

        connectionState = .disconnected
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        receiveTask?.cancel()
        pingTask?.cancel()

        delegate?.webSocketDidDisconnect(error: error)

        guard shouldReconnect, reconnectAttempt < maxReconnectAttempts else {
            print("[WebSocket] Max reconnect attempts reached or reconnect disabled.")
            return
        }

        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectAttempt += 1

        // Exponential backoff with jitter
        let delay = min(
            baseReconnectDelay * pow(2.0, Double(reconnectAttempt - 1)),
            maxReconnectDelay
        )
        let jitter = Double.random(in: 0...(delay * 0.3))
        let totalDelay = delay + jitter

        print("[WebSocket] Reconnecting in \(String(format: "%.1f", totalDelay))s (attempt \(reconnectAttempt)/\(maxReconnectAttempts))")

        connectionState = .reconnecting(attempt: reconnectAttempt)

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(totalDelay))
            guard let self, !Task.isCancelled, self.shouldReconnect else { return }
            self.establishConnection()
        }
    }

    // MARK: - Errors

    enum WebSocketError: LocalizedError {
        case notConnected

        var errorDescription: String? {
            switch self {
            case .notConnected:
                return "WebSocket is not connected"
            }
        }
    }
}
