import Foundation

/// Bytes the device signs to prove it holds the DIRECT ID's signing key for this bootstrap nonce.
public enum SignalProof {
    public static let prefix = "DIRECT-SIGNAL/1"

    public static func message(nonce: String, directId: String) -> Data {
        Encoding.utf8("\(prefix)\n\(nonce)\n\(directId)")
    }
}
