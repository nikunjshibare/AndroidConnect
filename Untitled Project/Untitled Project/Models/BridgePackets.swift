import Foundation

// MARK: - Wire Protocol Envelope

/// Top-level JSON envelope for all WebSocket messages between Mac and Android.
struct BridgeEnvelope: Codable {
    let type: BridgeMessageType
    let timestamp: Int
    let payload: BridgePayload
}

// MARK: - Message Types

enum BridgeMessageType: String, Codable {
    case telemetry = "TELEMETRY"
    case notification = "NOTIFICATION"
    case notificationReply = "NOTIFICATION_REPLY"
    case callState = "CALL_STATE"
    case callAction = "CALL_ACTION"
    case clipboard = "CLIPBOARD"
    case ringPhone = "RING_PHONE"
    case ping = "PING"
    case pong = "PONG"
}

// MARK: - Payload (tagged union via coding)

/// A payload container that decodes the correct concrete type based on the
/// parent envelope's `type` field. We use a flat coding strategy where
/// the envelope handles routing.
enum BridgePayload: Codable {
    case telemetry(TelemetryPayload)
    case notification(NotificationPayload)
    case notificationReply(NotificationReplyPayload)
    case callState(CallStatePayload)
    case callAction(CallActionPayload)
    case clipboard(ClipboardPayload)
    case ringPhone(RingPhonePayload)
    case ping
    case pong

    // We encode/decode via the envelope, so these are pass-through.
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .telemetry(let p):         try container.encode(p)
        case .notification(let p):      try container.encode(p)
        case .notificationReply(let p): try container.encode(p)
        case .callState(let p):         try container.encode(p)
        case .callAction(let p):        try container.encode(p)
        case .clipboard(let p):         try container.encode(p)
        case .ringPhone(let p):         try container.encode(p)
        case .ping, .pong:              try container.encode([String: String]())
        }
    }

    init(from decoder: Decoder) throws {
        // Default to ping — the envelope's custom decode overrides this.
        self = .ping
    }
}

// MARK: - Concrete Payloads

struct TelemetryPayload: Codable {
    let batteryPercent: Int
    let isCharging: Bool
    let signalStrength: Int       // 0–4 bars
    let networkType: String       // "WiFi", "LTE", "5G", etc.
    let storageFreeMB: Int
}

struct NotificationPayload: Codable {
    let id: String
    let appName: String
    let title: String
    let body: String
    let isOTP: Bool               // Android companion flags SMS containing OTP patterns
    let otpCode: String?          // Extracted OTP if isOTP == true
    let postedAt: Int             // Unix timestamp (seconds)
}

struct NotificationReplyPayload: Codable {
    let notificationId: String
    let replyText: String
}

enum CallDirection: String, Codable {
    case incoming = "INCOMING"
    case outgoing = "OUTGOING"
}

enum CallStatus: String, Codable {
    case ringing = "RINGING"
    case active = "ACTIVE"
    case held = "HELD"
    case ended = "ENDED"
}

struct CallStatePayload: Codable {
    let callId: String
    let phoneNumber: String
    let contactName: String?
    let direction: CallDirection
    let status: CallStatus
    let durationSeconds: Int?     // For active/ended calls
}

enum CallActionCommand: String, Codable {
    case answer = "ANSWER"
    case reject = "REJECT"
    case hangup = "HANGUP"
    case hold = "HOLD"
    case unhold = "UNHOLD"
    case dial = "DIAL"
}

struct CallActionPayload: Codable {
    let callId: String?
    let action: CallActionCommand
    let phoneNumber: String?      // Required for DIAL
}

struct ClipboardPayload: Codable {
    let text: String
    let source: ClipboardSource
}

enum ClipboardSource: String, Codable {
    case mac = "MAC"
    case android = "ANDROID"
}

struct RingPhonePayload: Codable {
    let durationSeconds: Int
}

// MARK: - Custom Envelope Decoding

extension BridgeEnvelope {
    /// Decodes a BridgeEnvelope from raw JSON data, correctly routing the
    /// payload to the appropriate concrete type.
    static func decode(from data: Data) throws -> BridgeEnvelope {
        // First pass: extract the type and timestamp
        struct Partial: Decodable {
            let type: BridgeMessageType
            let timestamp: Int
        }

        let partial = try JSONDecoder().decode(Partial.self, from: data)

        // Second pass: decode the full payload based on type
        struct FullEnvelope<P: Decodable>: Decodable {
            let type: BridgeMessageType
            let timestamp: Int
            let payload: P
        }

        let decoder = JSONDecoder()
        let payload: BridgePayload

        switch partial.type {
        case .telemetry:
            let full = try decoder.decode(FullEnvelope<TelemetryPayload>.self, from: data)
            payload = .telemetry(full.payload)
        case .notification:
            let full = try decoder.decode(FullEnvelope<NotificationPayload>.self, from: data)
            payload = .notification(full.payload)
        case .notificationReply:
            let full = try decoder.decode(FullEnvelope<NotificationReplyPayload>.self, from: data)
            payload = .notificationReply(full.payload)
        case .callState:
            let full = try decoder.decode(FullEnvelope<CallStatePayload>.self, from: data)
            payload = .callState(full.payload)
        case .callAction:
            let full = try decoder.decode(FullEnvelope<CallActionPayload>.self, from: data)
            payload = .callAction(full.payload)
        case .clipboard:
            let full = try decoder.decode(FullEnvelope<ClipboardPayload>.self, from: data)
            payload = .clipboard(full.payload)
        case .ringPhone:
            let full = try decoder.decode(FullEnvelope<RingPhonePayload>.self, from: data)
            payload = .ringPhone(full.payload)
        case .ping:
            payload = .ping
        case .pong:
            payload = .pong
        }

        return BridgeEnvelope(type: partial.type, timestamp: partial.timestamp, payload: payload)
    }
}

// MARK: - Envelope Construction Helpers

extension BridgeEnvelope {
    /// Creates a new envelope with the current timestamp.
    static func make(_ type: BridgeMessageType, payload: BridgePayload) -> BridgeEnvelope {
        BridgeEnvelope(
            type: type,
            timestamp: Int(Date().timeIntervalSince1970),
            payload: payload
        )
    }

    /// Encodes this envelope to JSON data for transmission.
    func jsonData() throws -> Data {
        try JSONEncoder().encode(self)
    }
}
