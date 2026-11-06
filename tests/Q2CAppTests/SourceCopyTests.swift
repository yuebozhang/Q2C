import Foundation
import Testing
@testable import Q2CApp

@MainActor
private final class CopyEnvironment: SourceCopyEnvironment {
    var canPostEvents = true
    var frontmostPID: pid_t? = 1234
    var modifiersReleased = true
    private var storedRevision = 10
    var revisionReads = 0
    var onRevisionRead: ((CopyEnvironment) -> Void)?
    var revision: Int {
        get { revisionReads += 1; onRevisionRead?(self); return storedRevision }
        set { storedRevision = newValue }
    }
    var sent = 0
    var ticks = 0
    var now: TimeInterval = 0
    var pauses: [TimeInterval] = []
    var onPause: ((CopyEnvironment) throws -> Void)?
    func pause(seconds: TimeInterval) async throws {
        ticks += 1
        pauses.append(seconds)
        now = (now + seconds) * 1_000_000
        now = now.rounded() / 1_000_000
        try onPause?(self)
    }
    var onCopy: ((CopyEnvironment) throws -> Void)?
    func sendCopy(to pid: pid_t) throws {
        sent += 1
        try onCopy?(self)
    }
    func publish() { storedRevision += 1 }
}

@Test @MainActor func unchangedClipboardNeverReadsOldTextOrRetriesCopy() async throws {
    let env = CopyEnvironment()
    do {
        _ = try await SystemSelection(environment: env).read()
        Issue.record("Expected copy timeout")
    } catch TextInputIssue.copyUnavailable { }
    #expect(env.sent == 1)
    #expect(env.revision == 10)
    #expect(env.now == 0.4)
    #expect(env.pauses.count == 8)
    #expect(env.pauses.allSatisfy { abs($0 - 0.05) < 0.000001 })
}

@Test @MainActor func newClipboardVersionReturnsOnlyReceiptAndObservationTimes() async throws {
    let env = CopyEnvironment()
    env.onCopy = { $0.publish() }
    let result = try await SystemSelection(environment: env).read()
    #expect(result.revision == 11)
    #expect(result.updateObservedAt >= result.copyRequestedAt)
    #expect(env.sent == 1)
}

@Test @MainActor func copyIsSentBeforeModifierReleaseAndOnlyOnce() async throws {
    let env = CopyEnvironment()
    env.modifiersReleased = false
    env.onCopy = { $0.publish() }
    let result = try await SystemSelection(environment: env).read()
    #expect(result.revision == 11)
    #expect(!env.modifiersReleased)
    #expect(env.sent == 1)
}

@Test @MainActor func permissionRejectionDoesNotCopy() async throws {
    let env = CopyEnvironment()
    env.canPostEvents = false
    do {
        _ = try await SystemSelection(environment: env).read()
        Issue.record("Expected permission rejection")
    } catch TextInputIssue.copyPermission { }
    #expect(env.sent == 0)
}

@Test @MainActor func changedClipboardDuringReadStopsInsteadOfUsingEarlierValue() async throws {
    let env = CopyEnvironment()
    env.onCopy = { $0.publish() }
    env.onRevisionRead = { if $0.revisionReads == 3 { $0.publish() } }
    do {
        _ = try await SystemSelection(environment: env).read()
        Issue.record("Expected clipboard change rejection")
    } catch TextInputIssue.clipboardChanged { }
    #expect(env.sent == 1)
}

@Test @MainActor func sourceChangeAfterCopyStopsBeforeReturningReceipt() async throws {
    let env = CopyEnvironment()
    env.onCopy = { $0.publish(); $0.frontmostPID = 4321 }
    do {
        _ = try await SystemSelection(environment: env).read()
        Issue.record("Expected source change")
    } catch TextInputIssue.sourceChanged { }
    #expect(env.sent == 1)
}

@Test @MainActor func cancelledSourceCopyDoesNotReturnReceipt() async throws {
    let env = CopyEnvironment()
    env.onCopy = { _ in throw CancellationError() }
    do {
        _ = try await SystemSelection(environment: env).read()
        Issue.record("Expected cancellation")
    } catch is CancellationError { }
    #expect(env.sent == 1)
}

@Test @MainActor func delayedCopyContinuesAtFirstObservationWithoutWaitingForDeadline() async throws {
    let env = CopyEnvironment()
    env.onPause = { if $0.ticks == 2 { $0.publish() } }
    let result = try await SystemSelection(environment: env).read()
    #expect(result.revision == 11)
    #expect(result.updateObservedAt == 0.1)
    #expect(env.pauses.count == 2)
    #expect(env.sent == 1)
}

@Test @MainActor func updateAtDeadlineIsAccepted() async throws {
    let env = CopyEnvironment()
    env.onPause = { if $0.ticks == 8 { $0.publish() } }
    let result = try await SystemSelection(environment: env).read()
    #expect(result.revision == 11)
    #expect(result.updateObservedAt == 0.4)
}

@Test @MainActor func lateCopyCannotExtendDeadlineOrRetry() async throws {
    let env = CopyEnvironment()
    env.onPause = { $0.now = 0.45; $0.publish() }
    do {
        _ = try await SystemSelection(environment: env).read()
        Issue.record("Expected deadline rejection")
    } catch TextInputIssue.copyUnavailable { }
    #expect(env.sent == 1)
    #expect(env.pauses.count == 1)
}

@Test @MainActor func sourceChangeWhileWaitingStopsCopy() async throws {
    let env = CopyEnvironment()
    env.onPause = { $0.frontmostPID = 4321 }
    do {
        _ = try await SystemSelection(environment: env).read()
        Issue.record("Expected source change")
    } catch TextInputIssue.sourceChanged { }
    #expect(env.pauses.count == 1)
}

@Test @MainActor func copyTimeoutDiagnosticsDistinguishUnchangedRevisionFromSourceChange() async throws {
    let env = CopyEnvironment()
    var events: [(String, [String: String])] = []
    let selection = SystemSelection(environment: env, diagnostic: { events.append(($0, $1)) })
    do {
        _ = try await selection.read()
        Issue.record("Expected timeout")
    } catch TextInputIssue.copyUnavailable { }
    let fields = try #require(events.last?.1)
    #expect(events.last?.0 == "source.copyFinished")
    #expect(fields["sourcePID"] == "1234")
    #expect(fields["frontmostPID"] == "1234")
    #expect(fields["revisionBefore"] == "10")
    #expect(fields["revisionAfter"] == "10")
    #expect(fields["elapsedMs"] == "400")
    #expect(fields["outcome"] == "rejected")
    #expect(fields["stage"] == "waitForUpdate")
    #expect(events.first?.1["copyID"] == fields["copyID"])
    #expect(env.sent == 1)
}

@Test @MainActor func sourceChangeDiagnosticsIncludeBothPIDsAndClipboardUpdate() async throws {
    let env = CopyEnvironment()
    env.onCopy = { $0.publish(); $0.frontmostPID = 4321 }
    var fields: [String: String] = [:]
    do {
        _ = try await SystemSelection(environment: env, diagnostic: { _, value in fields = value }).read()
        Issue.record("Expected source change")
    } catch TextInputIssue.sourceChanged { }
    #expect(fields["stage"] == "sourceCheck")
    #expect(fields["sourcePID"] == "1234")
    #expect(fields["frontmostPID"] == "4321")
    #expect(fields["revisionBefore"] == "10")
    #expect(fields["revisionAfter"] == "11")
    #expect(env.sent == 1)
}

@Test @MainActor func ownForegroundDiagnosticsIdentifyPreflightRejectionWithoutCopy() async throws {
    let env = CopyEnvironment()
    env.frontmostPID = ProcessInfo.processInfo.processIdentifier
    var fields: [String: String] = [:]
    do {
        _ = try await SystemSelection(environment: env, diagnostic: { _, value in fields = value }).read()
        Issue.record("Expected own foreground rejection")
    } catch TextInputIssue.sourceChanged { }
    #expect(fields["stage"] == "preflight")
    #expect(fields["sourcePID"] == fields["frontmostPID"])
    #expect(fields["revisionBefore"] == "unobserved")
    #expect(env.sent == 0)
}
