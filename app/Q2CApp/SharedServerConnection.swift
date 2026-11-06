import Foundation

/// Connect only to an existing service. Never create another writer for a desktop thread.
enum SharedServerConnection {
    static func socketURL(environment: [String: String] = ProcessInfo.processInfo.environment,
                          home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let explicit = environment["Q2C_APP_SERVER_SOCKET"], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit)
        }
        let codexHome = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex", isDirectory: true)
        return codexHome.appendingPathComponent("app-server-control/app-server-control.sock")
    }

    static func isSocket(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeSocket
    }
}
