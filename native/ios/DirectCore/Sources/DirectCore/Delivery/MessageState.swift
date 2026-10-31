import Foundation

/// Outgoing message lifecycle. The wire receipts keep their reference names: an `ack`
/// envelope moves a message to `accepted` and a `read` envelope moves it to `acknowledged`.
///
/// queued        sealed and persisted on this device, waiting for a route or for its retry time
/// sending       an attempt is opening the data channel and writing the envelope
/// sent          written to the recipient's open data channel; no receipt yet
/// accepted      the recipient device verified, decrypted, and stored it, and signed an `ack`
///               (an unknown sender's message is stored as a request, and is still accepted)
/// acknowledged  the recipient accepted the conversation and opened the message, and signed a `read`
/// failed        expired before any receipt, or the recipient is blocked; a manual retry requeues it
public enum MessageState: String, Codable, CaseIterable, Sendable {
    case queued = "QUEUED"
    case sending = "SENDING"
    case sent = "SENT"
    case accepted = "ACCEPTED"
    case acknowledged = "ACKNOWLEDGED"
    case failed = "FAILED"

    /// The queue keeps the payload only while a receipt is still outstanding.
    public var awaitingReceipt: Bool { self == .queued || self == .sending || self == .sent }
}

public enum DeliveryEvent: CaseIterable {
    /// A flush picked the message up.
    case attempt
    /// The envelope was written to an open data channel.
    case written
    /// No data channel could be opened, or the write failed.
    case unreachable
    /// Sent for longer than the receipt timeout. The recipient deduplicates, so a resend is safe.
    case receiptTimeout
    /// A verified `ack` from the recipient.
    case deliveryReceipt
    /// A verified `read` from the recipient.
    case readReceipt
    /// The envelope's expiry passed with no receipt.
    case expired
    /// The recipient is blocked on this device.
    case rejected
    /// The user asked to try a failed message again.
    case retry
    /// The app restarted while an attempt was in flight.
    case recovered
}

public enum DeliveryStateMachine {
    /// Returns the next state, or nil when the event does not apply and must be ignored.
    public static func next(_ state: MessageState, _ event: DeliveryEvent) -> MessageState? {
        switch event {
        case .attempt: return state == .queued ? .sending : nil
        case .written: return state == .sending ? .sent : nil
        case .unreachable: return state == .sending ? .queued : nil
        case .receiptTimeout: return state == .sent ? .queued : nil
        case .deliveryReceipt:
            switch state {
            case .queued, .sending, .sent, .failed: return .accepted
            default: return nil
            }
        case .readReceipt: return state == .acknowledged ? nil : .acknowledged
        case .expired, .rejected: return state.awaitingReceipt ? .failed : nil
        case .retry: return state == .failed ? .queued : nil
        case .recovered: return state == .sending || state == .sent ? .queued : nil
        }
    }
}

/// 1s, 2s, 4s, … capped at five minutes, plus up to 20% jitter. Same as packages/protocol/src/backoff.ts.
public enum Backoff {
    public static let baseMs: Int64 = 1_000
    public static let capMs: Int64 = 5 * 60 * 1_000

    public static func delayMs(attempt: Int, random: () -> Double = { Double.random(in: 0..<1) }) -> Int64 {
        let exponent = max(attempt - 1, 0)
        let exponential = min(Double(capMs), Double(baseMs) * pow(2.0, Double(min(exponent, 30))))
        return Int64((exponential + random() * exponential * 0.2).rounded())
    }
}
