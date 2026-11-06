import Foundation

/// Local diagnostics include document URLs for routing analysis, never message payloads or raw server responses.
final class DiagnosticLog: @unchecked Sendable {
    static let shared = DiagnosticLog()
    private let lock = NSLock()
    let directory: URL
    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Q2C", isDirectory: true)) {
        self.directory = directory
    }
    var fileURL: URL { directory.appendingPathComponent("diagnostic.jsonl") }

    func record(_ event: String, trace: String? = nil, fields: [String: String] = [:]) {
        lock.lock()
        defer { lock.unlock() }
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            if let size = try? manager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber,
               size.intValue >= 1_048_576 {
                let previous = directory.appendingPathComponent("diagnostic.previous.jsonl")
                if manager.fileExists(atPath: previous.path) { try manager.removeItem(at: previous) }
                try manager.moveItem(at: fileURL, to: previous)
            }
            if !manager.fileExists(atPath: fileURL.path) {
                guard manager.createFile(atPath: fileURL.path, contents: nil,
                                         attributes: [.posixPermissions: 0o600]) else { return }
            }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            var entry = fields
            entry["time"] = ISO8601DateFormatter().string(from: Date())
            entry["pid"] = String(ProcessInfo.processInfo.processIdentifier)
            entry["event"] = event
            entry["trace"] = trace
            var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            data.append(0x0A)
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Logging failures must not change submission behavior.
        }
    }
}
