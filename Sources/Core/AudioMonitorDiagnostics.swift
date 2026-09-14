import Foundation
import OSLog

/// Main-actor confinement makes the former trace NSLock unnecessary.
@MainActor
enum AudioMonitorDiagnostics {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "lee.miclock.app",
        category: "AudioMonitor"
    )
    private static let debug = ProcessInfo.processInfo.environment["MICLOCK_DEBUG"] != nil
    private static let path = ProcessInfo.processInfo.environment["MICLOCK_TRACE_PATH"]

    static func trace(_ message: String) {
        guard debug || path != nil, let data = (message + "\n").data(using: .utf8) else { return }
        if debug { FileHandle.standardError.write(data) }
        guard let path else { return }
        do {
            if let handle = FileHandle(forWritingAtPath: path) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: URL(fileURLWithPath: path))
            }
        } catch {
            logger.error("Trace write failed: \(String(describing: error), privacy: .public)")
        }
    }
}
