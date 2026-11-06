import Foundation
import Testing
import Q2CCore
@testable import Q2CApp

@MainActor
private final class FakeSelection: SelectionAccess {
    var content = CopiedContent(revision: 20, copyRequestedAt: 1, updateObservedAt: 1.02)
    var fail = false
    var readCount = 0
    var suspend = false
    var continuation: CheckedContinuation<Void, Never>?
    func read() async throws -> CopiedContent {
        readCount += 1
        if suspend { await withCheckedContinuation { continuation = $0 } }
        if fail { throw TextInputIssue.copyUnavailable }
        return content
    }
}

@MainActor
private final class FakePaster: ClipboardPasting {
    struct Request { let target: Target; let content: CopiedContent; let header: String; let footer: String }
    var requests = [Request]()
    var fail = false
    func paste(target: Target, content: CopiedContent, header: String, footer: String, traceID: String) async throws {
        requests.append(Request(target: target, content: content, header: header, footer: footer))
        if fail { throw AssistantError.adapterUnavailable }
    }
}

@MainActor
private func withModel(_ body: (AssistantModel, FakeSelection, FakePaster) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("q2c-model-tests-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let selection = FakeSelection(), paster = FakePaster()
    let model = AssistantModel(store: ConfigurationStore(directory: directory), selection: selection, paster: paster)
    defer { model.stop() }
    try await body(model, selection, paster)
}

private let firstLink = "codex://threads/11111111-1111-4111-8111-111111111111"
private let secondLink = "codex://threads/22222222-2222-4222-8222-222222222222"

@Test @MainActor func singleConfigurationForwardsOpaqueReceiptWithoutLegacyAffixesOnlyOnce() async throws {
    try await withModel { model, selection, paster in
        model.settings.targetLink = firstLink
        model.settings.messageHeader = "合成开头"
        model.settings.messageFooter = "合成结尾"
        await model.copySelectedContent()
        await model.copySelectedContent()
        #expect(selection.readCount == 1)
        for _ in 0..<20 where model.isPasting { await Task.yield() }
        #expect(paster.requests.count == 1)
        #expect(paster.requests.first?.content == selection.content)
        #expect(paster.requests.first?.header == "")
        #expect(paster.requests.first?.footer == "")
        #expect(paster.requests.first?.target.navigationURL?.absoluteString == firstLink)
        #expect(model.status.contains("已请求粘贴"))
        #expect(model.status.contains("手动发送"))
    }
}

@Test @MainActor func noNewCopyStopsBeforeNavigation() async throws {
    try await withModel { model, selection, paster in
        selection.fail = true
        await model.copySelectedContent()
        #expect(model.isError)
        #expect(model.status == TextInputIssue.copyUnavailable.localizedDescription)
        #expect(paster.requests.isEmpty)
        #expect(!model.isBusy)
    }
}

@Test @MainActor func chooserFreezesRevisionAndConfigurationAndDoesNotRecopy() async throws {
    try await withModel { model, selection, paster in
        let second = ForwardProfile(targetLink: secondLink, messageHeader: "第二组")
        model.profiles = [ForwardProfile(targetLink: firstLink), second]
        let original = selection.content
        await model.copySelectedContent(useFavorite: false)
        #expect(model.isChoosingTarget)
        #expect(paster.requests.isEmpty)
        selection.content = CopiedContent(revision: 99, copyRequestedAt: 2, updateObservedAt: 3)
        model.profiles[1].targetLink = firstLink
        model.chooseTarget(second.id)
        for _ in 0..<20 where model.isPasting { await Task.yield() }
        #expect(paster.requests.first?.content == original)
        #expect(paster.requests.first?.target.navigationURL?.absoluteString == secondLink)
        #expect(paster.requests.first?.header == "")
        #expect(selection.readCount == 1)
    }
}

@Test @MainActor func cancellingChooserDoesNotPasteOrReadAgain() async throws {
    try await withModel { model, selection, paster in
        model.profiles = [ForwardProfile(targetLink: firstLink), ForwardProfile(targetLink: secondLink)]
        await model.copySelectedContent(useFavorite: false)
        model.cancelTargetChoice()
        #expect(!model.isBusy)
        #expect(paster.requests.isEmpty)
        #expect(selection.readCount == 1)
    }
}

@Test @MainActor func invalidTargetStopsButHiddenLegacyAffixesAreIgnored() async throws {
    try await withModel { model, _, paster in
        await model.copySelectedContent()
        #expect(model.isError)
        #expect(paster.requests.isEmpty)
        model.settings.targetLink = firstLink
        model.settings.messageHeader = "\0"
        model.settings.messageFooter = "legacy footer"
        await model.copySelectedContent()
        for _ in 0..<20 where model.isPasting { await Task.yield() }
        #expect(paster.requests.count == 1)
        #expect(paster.requests.first?.header == "")
        #expect(paster.requests.first?.footer == "")
    }
}

@Test @MainActor func failedPasteDoesNotRetryAndAllowsANewTrigger() async throws {
    try await withModel { model, selection, paster in
        model.settings.targetLink = firstLink
        paster.fail = true
        await model.copySelectedContent()
        for _ in 0..<20 where model.isPasting { await Task.yield() }
        #expect(model.isError)
        #expect(!model.isBusy)
        #expect(paster.requests.count == 1)
        paster.fail = false
        await model.copySelectedContent()
        for _ in 0..<20 where model.isPasting { await Task.yield() }
        #expect(paster.requests.count == 2)
        #expect(selection.readCount == 2)
    }
}

@Test @MainActor func copyInProgressBlocksSecondTriggerAndFreezesConfiguration() async throws {
    try await withModel { model, selection, paster in
        model.settings.targetLink = firstLink
        selection.suspend = true
        let first = Task { @MainActor in await model.copySelectedContent() }
        for _ in 0..<30 where selection.continuation == nil { await Task.yield() }
        #expect(model.isReading)
        await model.copySelectedContent()
        #expect(selection.readCount == 1)
        model.settings.targetLink = secondLink
        selection.continuation?.resume()
        await first.value
        for _ in 0..<20 where model.isPasting { await Task.yield() }
        #expect(paster.requests.first?.target.navigationURL?.absoluteString == firstLink)
    }
}

@Test @MainActor func deletingLastProfileClearsItsDataAndKeepsAnEditableSlot() async throws {
    try await withModel { model, _, _ in
        model.settings.targetLink = firstLink
        model.settings.messageHeader = "合成开头"
        model.settings.messageFooter = "合成结尾"
        let original = model.profiles[0]
        model.removeProfile(original.id)
        #expect(model.profiles.count == 1)
        #expect(model.profiles[0].id != original.id)
        #expect(model.profiles[0].targetLink.isEmpty)
        #expect(model.profiles[0].messageHeader.isEmpty)
        #expect(model.profiles[0].messageFooter.isEmpty)
        #expect(model.profiles[0].shortcut == original.shortcut)
        #expect(model.hasUnsavedSettings)
    }
}

@Test @MainActor func emptyProfilePreventsAddingMoreUntilItsLinkIsFilled() async throws {
    try await withModel { model, _, _ in
        #expect(!model.canAddProfile)
        model.addProfile()
        #expect(model.profiles.count == 1)
        model.settings.targetLink = firstLink
        #expect(model.canAddProfile)
        model.addProfile()
        #expect(model.profiles.count == 2)
        #expect(!model.canAddProfile)
        model.profiles[1].targetLink = " \n "
        model.addProfile()
        #expect(model.profiles.count == 2)
        model.profiles[1].targetLink = secondLink
        #expect(model.canAddProfile)
    }
}

@Test @MainActor func profileLimitBlocksNinthAndDeletionAllowsAddingAgain() async throws {
    try await withModel { model, _, _ in
        model.settings.targetLink = firstLink
        for _ in 1..<8 {
            #expect(model.canAddProfile)
            model.addProfile()
            model.profiles[model.profiles.count - 1].targetLink = secondLink
        }
        #expect(model.profiles.count == 8)
        #expect(!model.canAddProfile)
        model.addProfile()
        #expect(model.profiles.count == 8)
        // All eight must also be persistable under the legacy unique-shortcut rule.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(directory: directory)
        try store.saveProfiles(model.profiles)
        #expect(try store.loadProfiles().count == 8)
        model.removeProfile(model.profiles.last!.id)
        #expect(model.canAddProfile)
        model.addProfile()
        #expect(model.profiles.count == 8)
    }
}

@Test @MainActor func favoriteRoutesDirectlyAndDeletionLeavesNoFavorite() async throws {
    try await withModel { model, selection, paster in
        model.settings.targetLink = firstLink
        model.addProfile()
        model.profiles[1].targetLink = secondLink
        model.favoriteProfile(model.profiles[1].id)
        #expect(model.profiles.filter(\.isFavorite).count == 1)
        await model.copySelectedContent()
        for _ in 0..<20 where model.isPasting { await Task.yield() }
        #expect(selection.readCount == 1)
        #expect(paster.requests.first?.target.navigationURL?.absoluteString == secondLink)
        model.addProfile()
        model.profiles[2].targetLink = firstLink
        model.removeProfile(model.profiles[1].id)
        #expect(!model.profiles.contains(where: { $0.isFavorite }))
        await model.copySelectedContent()
        #expect(model.isChoosingTarget)
        model.cancelTargetChoice()
    }
}

@MainActor private final class FakeInteraction: ShortcutResolving {
    var resolveAction: (([ForwardProfile], Int) -> ForwardProfile?)?
    var closed = false
    func resolve(profiles: [ForwardProfile], revision: Int) async throws -> ForwardProfile? {
        resolveAction?(profiles, revision)
    }
    func close() { closed = true }
}

@Test @MainActor func gestureCopiesBeforeChoosingAndUsesFrozenConfiguration() async throws {
    try await withModel { model, selection, paster in
        model.settings.targetLink = firstLink
        model.addProfile()
        model.profiles[1].targetLink = secondLink
        let interaction = FakeInteraction()
        interaction.resolveAction = { profiles, revision in
            #expect(selection.readCount == 1)
            #expect(revision == selection.content.revision)
            #expect(model.isBusy)
            model.profiles[1].targetLink = firstLink
            return profiles[1]
        }
        await model.copySelectedContent(interaction: interaction)
        for _ in 0..<20 where model.isPasting { await Task.yield() }
        #expect(paster.requests.first?.target.navigationURL?.absoluteString == secondLink)
        #expect(selection.readCount == 1)
        #expect(interaction.closed)
    }
}

@Test @MainActor func cancelledGestureAndCopyFailureNeverPaste() async throws {
    try await withModel { model, selection, paster in
        model.settings.targetLink = firstLink
        let interaction = FakeInteraction()
        await model.copySelectedContent(interaction: interaction)
        #expect(paster.requests.isEmpty)
        #expect(interaction.closed)
        selection.fail = true
        let failed = FakeInteraction()
        failed.resolveAction = { _, _ in Issue.record("Must not choose before copy succeeds"); return nil }
        await model.copySelectedContent(interaction: failed)
        #expect(paster.requests.isEmpty)
        #expect(failed.closed)
    }
}

@Test @MainActor func clickingFavoriteAgainClearsItAndAnotherClickSelectsIt() async throws {
    try await withModel { model, _, _ in
        let first = model.profiles[0].id
        model.favoriteProfile(first)
        #expect(!model.profiles.contains(where: { $0.isFavorite }))
        model.favoriteProfile(first)
        #expect(model.profiles[0].isFavorite)
        model.settings.targetLink = firstLink
        model.addProfile()
        model.favoriteProfile(model.profiles[1].id)
        #expect(!model.profiles[0].isFavorite)
        #expect(model.profiles[1].isFavorite)
    }
}
