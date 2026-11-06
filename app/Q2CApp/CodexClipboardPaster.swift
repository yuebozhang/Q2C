import AppKit
import ApplicationServices
import Q2CCore

@MainActor
protocol ClipboardPasting {
    func paste(target: Target, content: CopiedContent, header: String, footer: String, traceID: String) async throws
}

/// Only prepares a draft. Never presses Return or the Send button.
@MainActor
final class CodexClipboardPaster: ClipboardPasting {
    private var currentStage = "idle"
    func paste(target: Target, content: CopiedContent, header: String, footer: String, traceID: String) async throws {
        let started = ProcessInfo.processInfo.systemUptime
        do {
            try await performPaste(target: target, content: content, header: header, footer: footer, traceID: traceID)
        } catch {
            var fields = ["elapsedMs": milliseconds(since: started),
                          "errorType": String(reflecting: type(of: error)), "stage": currentStage]
            if let failure = error as? PasteError { fields["reason"] = String(describing: failure) }
            else if error is CancellationError { fields["reason"] = "cancelled" }
            DiagnosticLog.shared.record("paste.failureDetail", trace: traceID, fields: fields)
            throw error
        }
    }

    private func performPaste(target: Target, content: CopiedContent, header: String, footer: String, traceID: String) async throws {
        currentStage = "preflight"
        try Task.checkCancellation()
        guard NSPasteboard.general.changeCount == content.revision else { throw PasteError.changedClipboard }
        guard CGPreflightPostEventAccess() else { throw PasteError.permission }
        let started = ProcessInfo.processInfo.systemUptime
        DiagnosticLog.shared.record("paste.preflightPassed", trace: traceID, fields: ["mode": "direct", "delayMs": "200"])
        currentStage = "navigation"
        guard let url = target.navigationURL, NSWorkspace.shared.open(url) else { throw PasteError.navigation }
        DiagnosticLog.shared.record("paste.navigationRequested", trace: traceID)
        currentStage = "navigationDelay"
        DiagnosticLog.shared.record("paste.navigationDelayStarted", trace: traceID, fields: ["delayMs": "200"])
        try await Task.sleep(for: .milliseconds(200))
        DiagnosticLog.shared.record("paste.navigationDelayFinished", trace: traceID, fields: ["elapsedMs": milliseconds(since: started)])
        currentStage = "foregroundCheck"
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.openai.codex" else {
            throw PasteError.focus
        }
        let pid = app.processIdentifier
        func validate() throws {
            try Task.checkCancellation()
            guard NSPasteboard.general.changeCount == content.revision else { throw PasteError.changedClipboard }
            guard let front = NSWorkspace.shared.frontmostApplication,
                  front.processIdentifier == pid, front.bundleIdentifier == "com.openai.codex" else { throw PasteError.focus }
        }
        try validate()
        DiagnosticLog.shared.record("paste.foregroundConfirmed", trace: traceID, fields: ["axInputCheck": "skipped", "taskIdentityCheck": "skipped"])
        currentStage = "modifierRelease"
        let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        let initiallyHeld = !CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty
        DiagnosticLog.shared.record("paste.modifierCheck", trace: traceID, fields: ["waiting": String(initiallyHeld)])
        while !CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty {
            try validate()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw PasteError.modifiers }
            try await Task.sleep(for: .milliseconds(20))
        }
        try validate()
        DiagnosticLog.shared.record("paste.modifiersReleased", trace: traceID, fields: ["elapsedMs": milliseconds(since: started)])
        currentStage = "clipboard"
        try validate()
        DiagnosticLog.shared.record("paste.actionStarted", trace: traceID, fields: ["action": "clipboard", "affixes": "disabled"])
        try self.postPaste(to: pid)
        DiagnosticLog.shared.record("paste.actionRequested", trace: traceID, fields: ["action": "clipboard", "elapsedMs": milliseconds(since: started)])
        currentStage = "complete"
        DiagnosticLog.shared.record("paste.requested", trace: traceID, fields: ["elapsedMs": milliseconds(since: started), "mode": "direct"])
    }

    private func postPaste(to pid: pid_t) throws {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { throw PasteError.event }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
    }

    private func milliseconds(since start: TimeInterval) -> String {
        String(Int((ProcessInfo.processInfo.systemUptime - start) * 1000))
    }

}

/// Historical AX readiness policy; the current direct-paste path does not call this.
enum PasteReadiness {
    enum Evidence { case notReady, targetMatched, unidentified, otherTarget }
    enum Decision: Equatable { case ready, wait(TimeInterval), timedOut }
    static let timeout: TimeInterval = 7
    static let unidentifiedSettling: TimeInterval = 0.5

    static func decision(elapsed: TimeInterval, evidence: Evidence) -> Decision {
        guard elapsed < timeout else { return .timedOut }
        switch evidence {
        case .targetMatched: return .ready
        case .unidentified:
            return elapsed >= unidentifiedSettling ? .ready : .wait(unidentifiedSettling - elapsed)
        case .notReady, .otherTarget: return .wait(0.05)
        }
    }
}

private enum PasteError: LocalizedError {
    case changedClipboard, permission, navigation, input, focus, focusRequest, modifiers, target, event
    var errorDescription: String? {
        switch self {
        case .changedClipboard: "剪贴板已被其他操作更改，已停止粘贴。"
        case .permission: "请为 Q2C 授予辅助功能权限；消息已复制，可手动粘贴。"
        case .navigation: "无法打开 Codex 目标链接；消息已复制，可手动粘贴。"
        case .input: "Codex 输入框未就绪或无法唯一识别；消息已复制，可手动粘贴。"
        case .focus: "Codex 前台窗口或输入焦点发生变化，已停止粘贴。"
        case .focusRequest: "未能聚焦 Codex 输入框，已停止粘贴。"
        case .modifiers: "快捷键修饰键尚未释放，已停止粘贴。"
        case .target: "当前 Codex 文档指向其他任务，已停止粘贴。"
        case .event: "无法创建粘贴操作；消息已复制，可手动粘贴。"
        }
    }
}
