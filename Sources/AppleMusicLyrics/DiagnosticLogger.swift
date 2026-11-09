import Foundation

/// Small persistent log intended for user-submitted troubleshooting reports.
final class DiagnosticLogger: @unchecked Sendable {
    static let shared = DiagnosticLogger()

    private let fileManager: FileManager
    private let directoryURL: URL
    private let maximumBytes: UInt64
    private let queue = DispatchQueue(label: "music.diagnostics", qos: .utility)
    private let formatter: ISO8601DateFormatter

    let logFileURL: URL
    let previousLogFileURL: URL

    init(
        fileManager: FileManager = .default,
        directoryURL: URL? = nil,
        maximumBytes: UInt64 = 512 * 1024
    ) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/\(AppIdentity.name)", isDirectory: true)
        self.maximumBytes = maximumBytes
        self.logFileURL = self.directoryURL.appendingPathComponent("diagnostic.log")
        self.previousLogFileURL = self.directoryURL.appendingPathComponent("diagnostic.previous.log")
        self.formatter = ISO8601DateFormatter()
        self.formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func startSession() {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let locale = Locale.current.identifier
        info(
            "Session started; app=\(version) (\(build)); "
                + "os=\(ProcessInfo.processInfo.operatingSystemVersionString); locale=\(locale)"
        )
    }

    func info(_ message: String) {
        append(level: "INFO", message: message)
    }

    func warning(_ message: String) {
        append(level: "WARN", message: message)
    }

    func error(_ message: String) {
        append(level: "ERROR", message: message)
    }

    func contents() -> String {
        queue.sync {
            guard let data = try? Data(contentsOf: logFileURL),
                  let text = String(data: data, encoding: .utf8) else {
                return "No diagnostic log has been written yet.\n\nExpected location:\n\(logFileURL.path)"
            }
            return text
        }
    }

    /// Ensures Finder actions have a real file to select, even before an event is logged.
    func prepareFile() {
        queue.sync { ensureFileExists() }
    }

    func flush() { queue.sync {} }

    private func append(level: String, message: String) {
        let timestamp = Date()
        queue.async { self.write(level: level, message: message, timestamp: timestamp) }
    }

    private func write(level: String, message: String, timestamp: Date) {
        if let attributes = try? fileManager.attributesOfItem(atPath: logFileURL.path) {
            if let size = attributes[.size] as? NSNumber, size.uint64Value >= maximumBytes {
                rotate()
            }
        } else {
            ensureFileExists()
        }
        let sanitized = message.replacingOccurrences(of: "\n", with: " ")
        let line = "[\(formatter.string(from: timestamp))] [\(level)] \(sanitized)\n"
        guard let data = line.data(using: .utf8),
              let handle = try? FileHandle(forWritingTo: logFileURL) else {
            return
        }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
        }
    }

    private func ensureFileExists() {
        try? fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: logFileURL.path) {
            fileManager.createFile(atPath: logFileURL.path, contents: nil)
        }
    }

    private func rotate() {
        try? fileManager.removeItem(at: previousLogFileURL)
        do {
            try fileManager.moveItem(at: logFileURL, to: previousLogFileURL)
        } catch {
            try? Data().write(to: logFileURL)
        }
        fileManager.createFile(atPath: logFileURL.path, contents: nil)
    }
}
