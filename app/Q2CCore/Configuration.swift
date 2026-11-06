import Foundation

public struct LocalConfiguration: Codable, Equatable, Sendable {
    public var targetLink: String
    public var shortcut: KeyboardShortcut
    public var messageHeader: String
    public var messageFooter: String

    public init(targetLink: String = "", shortcut: KeyboardShortcut = .standard,
                messageHeader: String = MessageWrapper.defaultHeader, messageFooter: String = "") {
        self.targetLink = targetLink
        self.shortcut = shortcut
        self.messageHeader = messageHeader
        self.messageFooter = messageFooter
    }

    private enum CodingKeys: String, CodingKey {
        case targetLink, shortcut, messageHeader, messageFooter
    }

    private enum LegacyKeys: String, CodingKey { case targetID, shortcutKey }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        var link = try values.decode(String.self, forKey: .targetLink)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        if let oldID = try legacy.decodeIfPresent(String.self, forKey: .targetID), !oldID.isEmpty {
            guard let id = UUID(uuidString: oldID.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw AssistantError.invalidTarget
            }
            if link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Migrate the former ID-only configuration to the single task-link field.
                link = "codex://threads/" + id.uuidString.lowercased()
            } else {
                guard try Target(link: link).id == id else { throw AssistantError.invalidLink }
            }
        }
        let shortcut: KeyboardShortcut
        if let stored = try values.decodeIfPresent(KeyboardShortcut.self, forKey: .shortcut) {
            shortcut = stored
        } else if let key = try legacy.decodeIfPresent(String.self, forKey: .shortcutKey) {
            shortcut = try KeyboardShortcut.legacy(key: key)
        } else {
            shortcut = .standard
        }
        try shortcut.validate()
        self.init(targetLink: link, shortcut: shortcut,
                  messageHeader: try values.decodeIfPresent(String.self, forKey: .messageHeader) ?? MessageWrapper.defaultHeader,
                  messageFooter: try values.decodeIfPresent(String.self, forKey: .messageFooter) ?? "")
    }

    public func target() throws -> Target {
        try Target(link: targetLink)
    }
}

public struct ForwardProfile: Codable, Equatable, Sendable, Identifiable {
    public var note: String
    public var isFavorite: Bool
    public var id: UUID
    public var targetLink: String
    public var shortcut: KeyboardShortcut
    public var messageHeader: String
    public var messageFooter: String

    public init(id: UUID = UUID(), targetLink: String = "", shortcut: KeyboardShortcut = .standard,
                messageHeader: String = "", messageFooter: String = "", isFavorite: Bool = false, note: String = "") {
        self.note = note
        self.isFavorite = isFavorite
        self.id = id
        self.targetLink = targetLink
        self.shortcut = shortcut
        self.messageHeader = messageHeader
        self.messageFooter = messageFooter
    }

    private enum CodingKeys: String, CodingKey {
        case id, targetLink, shortcut, messageHeader, messageFooter, isFavorite, note
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(UUID.self, forKey: .id),
                  targetLink: try values.decode(String.self, forKey: .targetLink),
                  shortcut: try values.decode(KeyboardShortcut.self, forKey: .shortcut),
                  messageHeader: try values.decode(String.self, forKey: .messageHeader),
                  messageFooter: try values.decode(String.self, forKey: .messageFooter),
                  isFavorite: try values.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? true,
                  note: try values.decodeIfPresent(String.self, forKey: .note) ?? "")
    }

    /// Preserve no favorite; collapse multiple favorites (including legacy missing fields) to the first.
    public static func normalizedFavorites(_ profiles: [ForwardProfile]) -> [ForwardProfile] {
        let favoriteID = profiles.first(where: { $0.isFavorite })?.id
        return profiles.map { profile in
            var result = profile
            result.isFavorite = profile.id == favoriteID
            return result
        }
    }

    public init(configuration: LocalConfiguration) {
        self.init(targetLink: configuration.targetLink, shortcut: configuration.shortcut,
                  messageHeader: configuration.messageHeader, messageFooter: configuration.messageFooter)
    }

    public func target() throws -> Target { try Target(link: targetLink) }

    public var localConfiguration: LocalConfiguration {
        LocalConfiguration(targetLink: targetLink, shortcut: shortcut,
                           messageHeader: messageHeader, messageFooter: messageFooter)
    }
}

private struct ConfigurationCollection: Codable {
    var schemaVersion: Int
    var profiles: [ForwardProfile]
}

public struct ConfigurationStore: Sendable {
    public let directory: URL
    public let legacyDirectory: URL?
    public var fileURL: URL { directory.appendingPathComponent("config.local.json") }

    public init(directory: URL, legacyDirectory: URL? = nil) {
        self.directory = directory
        self.legacyDirectory = legacyDirectory
    }

    public func load() throws -> LocalConfiguration {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            if let collection = try? JSONDecoder().decode(ConfigurationCollection.self, from: data),
               collection.schemaVersion == 2,
               let first = collection.profiles.first {
                return first.localConfiguration
            }
            return try JSONDecoder().decode(LocalConfiguration.self, from: data)
        }
        if let legacyURL = legacyDirectory?.appendingPathComponent("config.local.json"),
           FileManager.default.fileExists(atPath: legacyURL.path) {
            var configuration = try JSONDecoder().decode(LocalConfiguration.self, from: Data(contentsOf: legacyURL))
            // Drop the former product-specific default, retaining custom templates.
            if configuration.messageHeader == "$sss" { configuration.messageHeader = "" }
            return configuration
        }
        return LocalConfiguration()
    }

    public func loadProfiles() throws -> [ForwardProfile] {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            if let collection = try? JSONDecoder().decode(ConfigurationCollection.self, from: data),
               collection.schemaVersion == 2 {
                guard !collection.profiles.isEmpty else { throw AssistantError.invalidTarget }
                return ForwardProfile.normalizedFavorites(collection.profiles)
            }
            return ForwardProfile.normalizedFavorites([migratedProfile(from: try JSONDecoder().decode(LocalConfiguration.self, from: data))])
        }
        return ForwardProfile.normalizedFavorites([migratedProfile(from: try load())])
    }

    private func migratedProfile(from original: LocalConfiguration) -> ForwardProfile {
        var configuration = original
        if configuration.shortcut == .previousStandard {
            configuration.shortcut = .standard
        }
        var profile = ForwardProfile(configuration: configuration)
        profile.isFavorite = true
        return profile
    }

    public func save(_ configuration: LocalConfiguration) throws {
        _ = try configuration.target()
        try MessageWrapper.validateAffixes(header: configuration.messageHeader, footer: configuration.messageFooter)
        try configuration.shortcut.validate()
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Harden existing directory as well. This location is dedicated to this app.
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try JSONEncoder().encode(configuration)
        try data.write(to: fileURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public func saveProfiles(_ profiles: [ForwardProfile]) throws {
        guard !profiles.isEmpty else { throw AssistantError.invalidTarget }
        guard Set(profiles.map(\.id)).count == profiles.count else { throw AssistantError.invalidTarget }
        let shortcutKeys = profiles.map { "\($0.shortcut.keyCode):\($0.shortcut.modifiers.rawValue)" }
        guard Set(shortcutKeys).count == shortcutKeys.count else { throw AssistantError.duplicateShortcut }
        for profile in profiles {
            if !profile.targetLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = try profile.target()
            }
            try MessageWrapper.validateAffixes(header: profile.messageHeader, footer: profile.messageFooter)
            try profile.shortcut.validate()
        }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try JSONEncoder().encode(ConfigurationCollection(schemaVersion: 2, profiles: ForwardProfile.normalizedFavorites(profiles)))
        try data.write(to: fileURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
