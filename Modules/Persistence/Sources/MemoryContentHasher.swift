import CryptoKit
import Foundation

/// Stable per-content fingerprint for `ai_memories.content_hash` (survives app restarts).
public enum MemoryContentHasher {
    public static func stableHash(_ content: String) -> String {
        let collapsed = content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[\\s\u{3000}]+", with: " ", options: .regularExpression)
        let digest = SHA256.hash(data: Data(collapsed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
