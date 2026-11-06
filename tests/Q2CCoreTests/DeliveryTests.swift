import Foundation
import Testing
@testable import Q2CCore

@MainActor
private final class FakeDesktop: DesktopTransport {
    var isVerified = true
    var targetID: UUID?
    var draft: String? = ""
    var attachments: Bool? = false
    var busy: Bool? = false
    var revision = "1"
    var fillCalls = 0
    var submitCalls = 0
    var throwOnSubmit = false
    var changeTargetAfterFill = false
    var raceOnFill = false
    var raceOnSubmit = false

    init(target: Target) { targetID = target.id }

    func inspect(target: Target) throws -> DesktopSnapshot {
        DesktopSnapshot(targetID: targetID, revision: revision, draft: draft, hasAttachments: attachments, busy: busy)
    }

    func fill(message: String, target: Target, expected: DesktopSnapshot) throws {
        if raceOnFill { revision = "changed" }
        guard try inspect(target: target) == expected else { throw AssistantError.changedState }
        fillCalls += 1
        draft = message
        revision = "2"
        if changeTargetAfterFill { targetID = UUID() }
    }

    func submit(message: String, target: Target, expected: DesktopSnapshot) throws {
        if raceOnSubmit { draft = "用户刚输入的合成草稿" }
        guard try inspect(target: target) == expected else { throw AssistantError.changedState }
        submitCalls += 1
        if throwOnSubmit { throw AssistantError.changedState }
        draft = ""
        revision = "3"
    }
}

@MainActor
private func fixture(routingPolicy: DesktopRoutingPolicy = .verifiedIdentity) throws -> (DeliverySession, FakeDesktop) {
    var buffer = CaptureBuffer()
    let target = try Target(id: "11111111-1111-4111-8111-111111111111", name: "合成任务")
    let capture = try buffer.capture(text: "合成输入文本", target: target)
    let desktop = FakeDesktop(target: target)
    return (DeliverySession(capture: capture, transport: desktop, routingPolicy: routingPolicy), desktop)
}

@Test @MainActor func mismatchedTargetNeverWrites() throws {
    let (session, desktop) = try fixture()
    desktop.targetID = UUID()
    #expect(throws: AssistantError.unverifiedTarget) { try session.stage() }
    #expect(desktop.fillCalls == 0)
}

@Test @MainActor func unknownTargetNeverWrites() throws {
    let (session, desktop) = try fixture()
    desktop.targetID = nil
    #expect(throws: AssistantError.unverifiedTarget) { try session.stage() }
    #expect(desktop.fillCalls == 0)
}

@Test @MainActor func existingWhitespaceDraftIsProtected() throws {
    let (session, desktop) = try fixture()
    desktop.draft = " \n"
    #expect(throws: AssistantError.existingDraft) { try session.stage() }
    #expect(desktop.draft == " \n")
    #expect(desktop.fillCalls == 0)
}

@Test @MainActor func attachmentOnlyDraftIsProtected() throws {
    let (session, desktop) = try fixture()
    desktop.attachments = true
    #expect(throws: AssistantError.existingDraft) { try session.stage() }
    #expect(desktop.fillCalls == 0)
}

@Test @MainActor func missingDraftOrAttachmentOrBusyEvidenceStops() throws {
    for field in 0..<3 {
        let (session, desktop) = try fixture()
        if field == 0 { desktop.draft = nil }
        if field == 1 { desktop.attachments = nil }
        if field == 2 { desktop.busy = nil }
        #expect(throws: AssistantError.unreadableDraft) { try session.stage() }
        #expect(desktop.fillCalls == 0)
    }
}

@Test @MainActor func busyTaskIsNotInterrupted() throws {
    let (session, desktop) = try fixture()
    desktop.busy = true
    #expect(throws: AssistantError.busy) { try session.stage() }
    #expect(desktop.fillCalls == 0)
}

@Test @MainActor func unverifiedAdapterCannotWrite() throws {
    let (session, desktop) = try fixture()
    desktop.isVerified = false
    #expect(throws: AssistantError.adapterUnavailable) { try session.stage() }
    #expect(desktop.fillCalls == 0)
}

@Test @MainActor func productionTransportIsUnavailable() throws {
    let (fixture, _) = try fixture()
    let session = DeliverySession(capture: fixture.capture, transport: UnavailableDesktopTransport())
    #expect(throws: AssistantError.adapterUnavailable) { try session.stage() }
    #expect(session.state == .prepared)
}

@Test @MainActor func changedSnapshotAtWriteBoundaryDoesNotFill() throws {
    let (session, desktop) = try fixture()
    desktop.raceOnFill = true
    #expect(throws: AssistantError.changedState) { try session.stage() }
    #expect(desktop.fillCalls == 0)
    #expect(throws: AssistantError.invalidTransition) { try session.stage() }
}

@Test @MainActor func targetChangeAfterFillNeverSubmits() throws {
    let (session, desktop) = try fixture()
    desktop.changeTargetAfterFill = true
    #expect(throws: AssistantError.unverifiedTarget) { try session.stage() }
    #expect(throws: AssistantError.invalidTransition) { try session.submit() }
    #expect(desktop.submitCalls == 0)
}

@Test @MainActor func editsAfterStagingArePreserved() throws {
    let (session, desktop) = try fixture()
    try session.stage()
    desktop.draft = "用户自己的合成草稿"
    #expect(throws: AssistantError.changedState) { try session.submit() }
    #expect(desktop.draft == "用户自己的合成草稿")
    #expect(desktop.submitCalls == 0)
}

@Test @MainActor func duplicateSubmitIsBlockedWhileAwaitingAcknowledgement() throws {
    let (session, desktop) = try fixture()
    try session.stage()
    try session.submit()
    #expect(session.state == .submitting)
    #expect(throws: AssistantError.invalidTransition) { try session.submit() }
    #expect(desktop.submitCalls == 1)
}

@Test @MainActor func timeoutIsUncertainAndCannotRetry() throws {
    let (session, desktop) = try fixture()
    try session.stage()
    try session.submit()
    try session.submissionTimedOut()
    #expect(session.state == .uncertain)
    #expect(throws: AssistantError.uncertainSubmission) { try session.submit() }
    #expect(desktop.submitCalls == 1)
}

@Test @MainActor func errorAfterSubmitMayHaveSentAndCannotRetry() throws {
    let (session, desktop) = try fixture()
    try session.stage()
    desktop.throwOnSubmit = true
    #expect(throws: AssistantError.uncertainSubmission) { try session.submit() }
    #expect(session.state == .uncertain)
    #expect(throws: AssistantError.uncertainSubmission) { try session.submit() }
    #expect(desktop.submitCalls == 1)
}

@Test @MainActor func lastMomentDraftChangeNeverPressesSubmit() throws {
    let (session, desktop) = try fixture()
    try session.stage()
    desktop.raceOnSubmit = true
    #expect(throws: AssistantError.uncertainSubmission) { try session.submit() }
    #expect(desktop.submitCalls == 0)
    #expect(desktop.draft == "用户刚输入的合成草稿")
}

@Test @MainActor func acknowledgementMustMatchBothTargetAndEvent() throws {
    let (session, _) = try fixture()
    try session.stage()
    try session.submit()
    #expect(throws: AssistantError.invalidTransition) {
        try session.acknowledge(captureID: UUID(), targetID: session.capture.target.id)
    }
    #expect(throws: AssistantError.invalidTransition) {
        try session.acknowledge(captureID: session.capture.id, targetID: UUID())
    }
    #expect(session.state == .submitting)
}

@Test @MainActor func lateAcknowledgementResolvesUncertaintyWithoutResubmitting() throws {
    let (session, desktop) = try fixture()
    try session.stage()
    try session.submit()
    try session.submissionTimedOut()
    try session.acknowledge(captureID: session.capture.id, targetID: session.capture.target.id)
    #expect(session.state == .submitted)
    #expect(desktop.submitCalls == 1)
}

@Test @MainActor func submittedRunningAndCompletedAreSeparateStates() throws {
    let (session, desktop) = try fixture()
    try session.stage()
    #expect(session.state == .staged)
    #expect(desktop.submitCalls == 0)
    try session.submit()
    #expect(throws: AssistantError.invalidTransition) { try session.finish(success: true) }
    try session.acknowledge(captureID: session.capture.id, targetID: session.capture.target.id)
    #expect(session.state == .submitted)
    try session.markRunning()
    #expect(session.state == .running)
    try session.finish(success: true)
    #expect(session.state == .completed)
    #expect(throws: AssistantError.invalidTransition) { try session.submit() }
}

@Test @MainActor func failedAnswerDoesNotPermitResubmission() throws {
    let (session, desktop) = try fixture()
    try session.stage()
    try session.submit()
    try session.acknowledge(captureID: session.capture.id, targetID: session.capture.target.id)
    try session.finish(success: false)
    #expect(session.state == .failed)
    #expect(throws: AssistantError.invalidTransition) { try session.submit() }
    #expect(desktop.submitCalls == 1)
}

@Test @MainActor func configuredNavigationAllowsMissingDocumentIdentity() throws {
    let (session, desktop) = try fixture(routingPolicy: .configuredNavigation)
    desktop.targetID = nil
    try session.stage()
    try session.submit()
    #expect(desktop.fillCalls == 1)
    #expect(desktop.submitCalls == 1)
    #expect(session.state == .submitting)
}

@Test @MainActor func configuredNavigationStillRejectsContraryIdentity() throws {
    let (session, desktop) = try fixture(routingPolicy: .configuredNavigation)
    desktop.targetID = UUID()
    #expect(throws: AssistantError.unverifiedTarget) { try session.stage() }
    #expect(desktop.fillCalls == 0)
}

@Test @MainActor func configuredNavigationPreservesDraftsAndAttachments() throws {
    for hasAttachment in [true, false] {
        let (session, desktop) = try fixture(routingPolicy: .configuredNavigation)
        desktop.targetID = nil
        desktop.attachments = hasAttachment
        desktop.draft = hasAttachment ? "" : "合成未发送草稿"
        #expect(throws: AssistantError.existingDraft) { try session.stage() }
        #expect(desktop.fillCalls == 0)
    }
}
