import Foundation
import Testing
@testable import Q2CCore

private func withTemporaryStore(_ body: (ConfigurationStore) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("q2c-tests-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(ConfigurationStore(directory: directory))
}

@Test func missingConfigurationStartsWithNoTarget() throws {
    try withTemporaryStore { store in
        let config = try store.load()
        #expect(config.targetLink.isEmpty)
        #expect(throws: AssistantError.invalidLink) { try config.target() }
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }
}

@Test func configurationRoundTripIsPrivateAndContainsNoConversation() throws {
    try withTemporaryStore { store in
        let config = LocalConfiguration(targetLink: "codex://threads/11111111-1111-4111-8111-111111111111",
                                        shortcut: KeyboardShortcut(keyCode: 40, modifiers: [.control, .option], keyLabel: "K"),
                                        messageHeader: "合成开头", messageFooter: "合成结尾\n第二行")
        try store.save(config)
        #expect(try store.load() == config)
        let file = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        let directory = try FileManager.default.attributesOfItem(atPath: store.directory.path)
        #expect((file[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((directory[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        #expect(Set(object.keys) == Set(["targetLink", "shortcut", "messageHeader", "messageFooter"]))
        #expect(try store.load().target().id == UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
    }
}

@Test func legacyConfigurationGetsDefaultAffixesWithoutLosingTarget() throws {
    try withTemporaryStore { store in
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let legacy = #"{"targetName":"合成旧任务","targetID":"11111111-1111-4111-8111-111111111111","targetLink":"","shortcutKey":"D"}"#
        try Data(legacy.utf8).write(to: store.fileURL)
        let config = try store.load()
        #expect(config.targetLink == "codex://threads/11111111-1111-4111-8111-111111111111")
        #expect(try config.target().id == UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        #expect(config.shortcut == KeyboardShortcut(keyCode: 2, modifiers: [.command, .shift], keyLabel: "D"))
        #expect(config.messageHeader.isEmpty)
        #expect(config.messageFooter.isEmpty)
    }
}

@Test func invalidAffixesDoNotOverwriteSavedConfiguration() throws {
    try withTemporaryStore { store in
        let valid = LocalConfiguration(targetLink: "codex://threads/11111111-1111-4111-8111-111111111111")
        try store.save(valid)
        var invalid = valid
        invalid.messageFooter = "合成\0结尾"
        #expect(throws: AssistantError.invalidText) { try store.save(invalid) }
        invalid.messageFooter = String(repeating: "中", count: 22_000)
        #expect(throws: AssistantError.tooLarge) { try store.save(invalid) }
        #expect(try store.load() == valid)
    }
}

@Test func invalidConfigurationDoesNotOverwriteExistingSettings() throws {
    try withTemporaryStore { store in
        let valid = LocalConfiguration(targetLink: "codex://threads/11111111-1111-4111-8111-111111111111")
        try store.save(valid)
        #expect(throws: AssistantError.invalidLink) { try store.save(LocalConfiguration()) }
        #expect(try store.load() == valid)
    }
}

@Test func legacyLinkMigrationKeepsFormattingAndRejectsConflictingIDs() throws {
    let matching = #"{"targetName":"合成旧任务","targetID":"11111111-1111-4111-8111-111111111111","targetLink":"codex://threads/11111111-1111-4111-8111-111111111111","shortcutKey":"S","messageHeader":"合成开头","messageFooter":"合成结尾"}"#
    let config = try JSONDecoder().decode(LocalConfiguration.self, from: Data(matching.utf8))
    #expect(config.targetLink == "codex://threads/11111111-1111-4111-8111-111111111111")
    #expect(config.messageHeader == "合成开头")
    #expect(config.messageFooter == "合成结尾")
    let conflicting = matching.replacingOccurrences(of: "codex://threads/11111111-1111-4111-8111-111111111111",
                                                    with: "codex://threads/22222222-2222-4222-8222-222222222222")
    #expect(throws: AssistantError.invalidLink) {
        try JSONDecoder().decode(LocalConfiguration.self, from: Data(conflicting.utf8))
    }
}

@Test func corruptConfigurationDoesNotSilentlyChooseAnotherTarget() throws {
    try withTemporaryStore { store in
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("broken synthetic config".utf8).write(to: store.fileURL)
        #expect(throws: (any Error).self) { try store.load() }
    }
}

@Test func oldSettingsAreReadWithoutOverwritingAndGenericSettingsTakePrecedence() throws {
    try withTemporaryStore { oldStore in
        let newDirectory = oldStore.directory.appendingPathComponent("Q2C")
        let newStore = ConfigurationStore(directory: newDirectory, legacyDirectory: oldStore.directory)
        var legacy = LocalConfiguration(targetLink: "codex://threads/11111111-1111-4111-8111-111111111111", messageHeader: "$sss", messageFooter: "合成结尾")
        try oldStore.save(legacy)
        let migrated = try newStore.load()
        #expect(migrated.messageHeader.isEmpty)
        #expect(migrated.messageFooter == legacy.messageFooter)
        #expect(migrated.targetLink == legacy.targetLink)
        #expect(!FileManager.default.fileExists(atPath: newStore.fileURL.path))
        #expect(try oldStore.load().messageHeader == "$sss")
        legacy.messageHeader = "自定义处理要求"
        try oldStore.save(legacy)
        #expect(try newStore.load().messageHeader == "自定义处理要求")
        var current = migrated
        current.messageHeader = "Q2C 设置"
        try newStore.save(current)
        #expect(try newStore.load().messageHeader == "Q2C 设置")
    }
}

@Test func favoritesMigrateFromOldCollectionsAndPersistSelection() throws {
    try withTemporaryStore { store in
        let first = ForwardProfile(targetLink: "codex://threads/11111111-1111-4111-8111-111111111111")
        var second = ForwardProfile(targetLink: "codex://threads/22222222-2222-4222-8222-222222222222",
                                    shortcut: KeyboardShortcut(keyCode: 8, modifiers: [.command, .shift], keyLabel: "C"))
        try store.saveProfiles([first, second])
        let data = try Data(contentsOf: store.fileURL)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var profiles = try #require(json["profiles"] as? [[String: Any]])
        for index in profiles.indices { profiles[index].removeValue(forKey: "isFavorite") }
        json["profiles"] = profiles
        try JSONSerialization.data(withJSONObject: json).write(to: store.fileURL)
        let migrated = try store.loadProfiles()
        #expect(migrated[0].isFavorite)
        #expect(!migrated[1].isFavorite)
        second.isFavorite = true
        try store.saveProfiles([first, second])
        let reloaded = try store.loadProfiles()
        #expect(!reloaded[0].isFavorite)
        #expect(reloaded[1].isFavorite)
        try store.saveProfiles([first, ForwardProfile(targetLink: second.targetLink, shortcut: second.shortcut)])
        #expect(try !store.loadProfiles().contains(where: { $0.isFavorite }))
        #expect(ForwardProfile.normalizedFavorites(reloaded.map { profile in
            var result = profile
            result.isFavorite = true
            return result
        }).filter(\.isFavorite).count == 1)
    }
}

@Test func optionalProfileNotePersistsAndOlderProfilesDecodeWithoutIt() throws {
    try withTemporaryStore { store in
        let profile = ForwardProfile(targetLink: "codex://threads/11111111-1111-4111-8111-111111111111", note: "合成备注")
        try store.saveProfiles([profile])
        #expect(try store.loadProfiles()[0].note == "合成备注")
        #expect(try store.loadProfiles()[0].messageHeader.isEmpty)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        json.removeValue(forKey: "note")
        let decoded = try JSONDecoder().decode(ForwardProfile.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.note.isEmpty)
    }
}
