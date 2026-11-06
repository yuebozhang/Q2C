import AppKit
import ApplicationServices

/// Metadata only. The original clipboard items and representations stay with macOS.
struct CopiedContent: Equatable, Sendable {
    let revision: Int
    let copyRequestedAt: TimeInterval
    let updateObservedAt: TimeInterval
}

@MainActor
protocol SelectionAccess { func read() async throws -> CopiedContent }

@MainActor
protocol SourceCopyEnvironment {
    var canPostEvents: Bool { get }
    var frontmostPID: pid_t? { get }
    var modifiersReleased: Bool { get }
    var revision: Int { get }
    var now: TimeInterval { get }
    func sendCopy(to pid: pid_t) throws
    func pause(seconds: TimeInterval) async throws
}

@MainActor
final class SystemSelection: SelectionAccess {
    private let environment: any SourceCopyEnvironment
    private let diagnostic: (String, [String: String]) -> Void
    init(environment: any SourceCopyEnvironment = MacSourceCopyEnvironment(),
         diagnostic: @escaping (String, [String: String]) -> Void = {
             DiagnosticLog.shared.record($0, fields: $1)
         }) {
        self.environment = environment
        self.diagnostic = diagnostic
    }

    func read() async throws -> CopiedContent {
        let started = environment.now
        let copyID = UUID().uuidString
        let sourcePID = environment.frontmostPID
        var stage = "preflight"
        var outcome = "rejected"
        var before: Int?
        var observedRevision: Int?
        defer {
            diagnostic("source.copyFinished", [
                "copyID": copyID, "stage": stage, "outcome": outcome,
                "sourcePID": sourcePID.map { String($0) } ?? "none",
                "frontmostPID": environment.frontmostPID.map { String($0) } ?? "none",
                "revisionBefore": before.map { String($0) } ?? "unobserved",
                "revisionObserved": observedRevision.map { String($0) } ?? "unobserved",
                "revisionAfter": String(environment.revision),
                "elapsedMs": String(Int((environment.now - started) * 1000))
            ])
        }
        try Task.checkCancellation()
        guard environment.canPostEvents else { throw TextInputIssue.copyPermission }
        guard let pid = sourcePID, pid != ProcessInfo.processInfo.processIdentifier else {
            throw TextInputIssue.sourceChanged
        }
        let initialRevision = environment.revision
        before = initialRevision
        diagnostic("source.copyStarted", ["copyID": copyID, "stage": "request",
            "sourcePID": String(pid), "frontmostPID": String(pid),
            "revisionBefore": String(initialRevision), "elapsedMs": String(Int((environment.now - started) * 1000))])
        stage = "request"
        let requestedAt = environment.now
        try environment.sendCopy(to: pid)
        stage = "sourceCheck"
        // Observe immediately, then every 50ms until the 400ms deadline.
        // No payload reads, old-clipboard fallback, or extra wait after an update.
        let deadline = requestedAt + 0.4
        while true {
            try Task.checkCancellation()
            stage = "sourceCheck"
            guard environment.frontmostPID == pid else { throw TextInputIssue.sourceChanged }
            stage = "deadlineCheck"
            guard environment.now <= deadline else { throw TextInputIssue.copyUnavailable }
            let revision = environment.revision
            observedRevision = revision
            if revision != initialRevision {
                stage = "revisionCheck"
                let observedAt = environment.now
                guard environment.revision == revision else { throw TextInputIssue.clipboardChanged }
                outcome = "ready"
                stage = "ready"
                return CopiedContent(revision: revision, copyRequestedAt: requestedAt, updateObservedAt: observedAt)
            }
            let remaining = deadline - environment.now
            stage = "waitForUpdate"
            guard remaining > 0 else { throw TextInputIssue.copyUnavailable }
            try await environment.pause(seconds: min(0.05, remaining))
        }
    }
}

@MainActor
private final class MacSourceCopyEnvironment: SourceCopyEnvironment {
    var canPostEvents: Bool { CGPreflightPostEventAccess() }
    var frontmostPID: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var modifiersReleased: Bool {
        CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty
    }
    var revision: Int { NSPasteboard.general.changeCount }
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    func pause(seconds: TimeInterval) async throws { try await Task.sleep(for: .seconds(seconds)) }
    func sendCopy(to pid: pid_t) throws {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false) else {
            throw TextInputIssue.copyUnavailable
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
    }
}

enum TextInputIssue: Error, LocalizedError {
    case copyPermission, sourceChanged, keysHeld, copyUnavailable, clipboardChanged
    var errorDescription: String? {
        switch self {
        case .copyPermission: "Q2C 无法发送复制快捷键，请检查系统设置中的辅助功能权限。"
        case .sourceChanged: "来源应用已切换，请重新选中内容后按快捷键。"
        case .keysHeld: "请松开快捷键后重试。"
        case .copyUnavailable:
            UserDefaults.standard.bool(forKey: "Q2C.interfaceEnglish")
                ? "No selection. Select content and press the shortcut."
                : "未选中任何内容 请选中后按快捷键"
        case .clipboardChanged: "复制期间剪贴板再次变化，已停止，请重新操作。"
        }
    }
}
