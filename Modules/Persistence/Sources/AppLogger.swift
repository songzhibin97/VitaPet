import os.log

public enum AppLogger: Sendable {
    private static let logger = Logger(subsystem: "com.vitapet.app", category: "general")

    public static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    public static func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }

    public static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }
}
