import AppKit
import ApplicationServices
import Q2CCore

@MainActor
final class CodexDesktopSender {
    enum Event { case submitted, failed(String), uncertain(String) }

    func submit(capture: Capture, traceID: String,
                onEvent: @escaping @MainActor (Event) -> Void) {
        let target = capture.target
        let message = capture.message
        Task { @MainActor in
            var pressed = false
            do {
                guard AXIsProcessTrusted() else { throw DesktopError.permission }
                guard let url = target.navigationURL, NSWorkspace.shared.open(url) else {
                    throw DesktopError.navigation
                }
                DiagnosticLog.shared.record("desktop.navigationRequested", trace: traceID)
                let adapter = AXCodexTransport(traceID: traceID)
                // The user selected deep-link routing. Give navigation time to settle;
                // a document URL is diagnostic rather than mandatory identity proof.
                try await Task.sleep(for: .seconds(1))
                var ready = false
                var readinessError: Error = DesktopError.identity
                for _ in 0..<30 {
                    try await Task.sleep(for: .milliseconds(200))
                    do {
                        _ = try adapter.inspect(target: target)
                        ready = true
                        break
                    } catch { readinessError = error }
                }
                guard ready else { throw readinessError }
                let session = DeliverySession(capture: capture, transport: adapter, routingPolicy: .configuredNavigation)
                try session.stage()
                DiagnosticLog.shared.record("desktop.filled", trace: traceID)
                try session.submit()
                pressed = true
                DiagnosticLog.shared.record("desktop.sendPressed", trace: traceID)
                // Input clearing alone is not an acknowledgement. Require a new visible
                // occurrence of the exact message outside the composer in this window.
                for _ in 0..<40 {
                    try await Task.sleep(for: .milliseconds(200))
                    if try adapter.acknowledged(message: message, target: target) {
                        try session.acknowledge(captureID: capture.id, targetID: target.id)
                        DiagnosticLog.shared.record("desktop.messageObserved", trace: traceID)
                        onEvent(.submitted)
                        return
                    }
                }
                throw AssistantError.uncertainSubmission
            } catch {
                let uncertain = pressed || (error as? AssistantError) == .uncertainSubmission
                DiagnosticLog.shared.record("desktop.failed", trace: traceID,
                    fields: ["errorType": String(reflecting: type(of: error)),
                             "reason": (error as? DesktopError)?.rawValue ?? ((error as? AssistantError).map { String(describing: $0) } ?? "unknown"),
                             "uncertain": String(uncertain)])
                let description = uncertain
                    ? "发送结果待确认，请查看 Codex；Q2C 不会自动重试。"
                    : error.localizedDescription
                if uncertain { onEvent(.uncertain(description)) }
                else { onEvent(.failed(description)) }
            }
        }
    }
}

private enum DesktopError: String, LocalizedError {
    case permission, navigation, identity, composer, writable, changed, press
    var errorDescription: String? {
        switch self {
        case .permission: "Q2C 没有辅助功能权限，请在系统设置中重新授权。"
        case .navigation: "无法打开 Codex 目标任务链接。"
        case .identity: "Codex 前台窗口或输入区域尚未就绪，已停止。"
        case .composer: "无法可靠识别 Codex 输入框、附件区域或发送按钮，已停止。"
        case .writable: "Codex 输入框不支持辅助功能写入，已停止。"
        case .changed: "Codex 窗口或输入内容发生变化，已停止；已填入的内容会保留。"
        case .press: "无法确认发送按钮是否已触发，请检查 Codex。"
        }
    }
}

/// Strict AX adapter. Unsupported UI layouts fail closed; no coordinate/Return fallback.
@MainActor
private final class AXCodexTransport: DesktopTransport {
    private(set) var isVerified = false
    private var baseline = 0
    private let traceID: String
    init(traceID: String) { self.traceID = traceID }
    private let sendLabels: Set<String> = ["send", "send message", "submit", "发送", "发送消息", "提交"]
    private let attachLabels: Set<String> = ["attach", "attach files", "add files", "add files and more", "附件", "添加附件", "添加文件"]
    private let stopLabels: Set<String> = ["stop", "stop generating", "stop response", "停止", "停止生成", "停止回答"]

    private struct View {
        let window: AXUIElement
        let input: AXUIElement
        let composer: AXUIElement
        let send: AXUIElement
        let nodes: [AXUIElement]
        let snapshot: DesktopSnapshot
    }

    func inspect(target: Target) throws -> DesktopSnapshot {
        let view = try read(target: target)
        isVerified = true
        return view.snapshot
    }

    func fill(message: String, target: Target, expected: DesktopSnapshot) throws {
        let view = try read(target: target)
        guard view.snapshot == expected else { throw DesktopError.changed }
        try requireSafe(view.snapshot, draft: "")
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(view.input, kAXValueAttribute as CFString, &settable) == .success,
              settable.boolValue else { throw DesktopError.writable }
        guard AXUIElementSetAttributeValue(view.input, kAXValueAttribute as CFString, message as CFString) == .success else {
            throw DesktopError.writable
        }
        let after = try read(target: target)
        try requireSafe(after.snapshot, draft: message)
    }

    func submit(message: String, target: Target, expected: DesktopSnapshot) throws {
        let view = try read(target: target)
        guard view.snapshot == expected else { throw DesktopError.changed }
        try requireSafe(view.snapshot, draft: message)
        guard (attribute(view.send, kAXEnabledAttribute) as? Bool) == true else { throw AssistantError.busy }
        baseline = occurrences(message: message, view: view)
        // Final identity/draft recheck at the actual button boundary.
        let final = try read(target: target)
        guard final.snapshot == expected, CFEqual(final.send, view.send) else { throw DesktopError.changed }
        guard AXUIElementPerformAction(final.send, kAXPressAction as CFString) == .success else { throw DesktopError.press }
    }

    func acknowledged(message: String, target: Target) throws -> Bool {
        let view = try read(target: target)
        return view.snapshot.draft == "" && occurrences(message: message, view: view) > baseline
    }

    private func requireSafe(_ snapshot: DesktopSnapshot, draft: String) throws {
        guard snapshot.busy == false else { throw AssistantError.busy }
        guard snapshot.hasAttachments == false else { throw AssistantError.existingDraft }
        guard snapshot.draft?.utf8.elementsEqual(draft.utf8) == true else {
            throw draft.isEmpty ? AssistantError.existingDraft : DesktopError.changed
        }
    }

    private func read(target: Target) throws -> View {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == "com.openai.codex" else { throw DesktopError.identity }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.25)
        guard let window = element(attribute(root, kAXFocusedWindowAttribute)) else { throw DesktopError.identity }
        let nodes = try descendants(window, limit: 1800)
        // Only the active window/document URL may prove routing. Sidebar links,
        // titles and the fact that open(url) succeeded never prove identity.
        var documents = [String]()
        var addressFields = ["expectedTargetID": target.id.uuidString.lowercased()]
        if let document = attribute(window, kAXDocumentAttribute) as? String {
            documents.append(document)
            addressFields["window.AXDocument"] = document
        }
        for (index, node) in nodes.enumerated() where role(node) == "AXWebArea" {
            let value = attribute(node, "AXURL")
            if let url = value as? URL {
                documents.append(url.absoluteString)
                addressFields["webArea.\(index).AXURL"] = url.absoluteString
            } else if let url = value as? String {
                documents.append(url)
                addressFields["webArea.\(index).AXURL"] = url
            }
        }
        let identityMatches = CodexDesktopIdentity.matches(documents: documents, targetID: target.id)
        addressFields["documentCount"] = String(documents.count)
        addressFields["matchesTarget"] = String(identityMatches)
        DiagnosticLog.shared.record("desktop.identityChecked", trace: traceID, fields: addressFields)
        let documentIDs = CodexDesktopIdentity.documentIDs(documents: documents)
        guard documentIDs.isEmpty || documentIDs == [target.id] else {
            DiagnosticLog.shared.record("desktop.identityMismatch", trace: traceID)
            throw AssistantError.unverifiedTarget
        }
        if documentIDs.isEmpty {
            DiagnosticLog.shared.record("desktop.routingByConfiguredLink", trace: traceID,
                                        fields: ["identityVerified": "false"])
        }
        let inputs = nodes.filter { role($0) == "AXTextArea" }
        DiagnosticLog.shared.record("desktop.inputCandidates", fields: ["count": String(inputs.count)])
        guard inputs.count == 1, let input = inputs.first,
              let draft = attribute(input, kAXValueAttribute) as? String else { throw DesktopError.composer }
        var parent = element(attribute(input, kAXParentAttribute))
        var found: (AXUIElement, AXUIElement, [AXUIElement])?
        for _ in 0..<6 {
            guard let group = parent, !CFEqual(group, window), role(group) != "AXWebArea" else { break }
            let members = try descendants(group, limit: 180)
            let sends = members.filter { role($0) == "AXButton" && sendLabels.union(stopLabels).contains(label($0)) }
            let attachments = members.filter { role($0) == "AXButton" && attachLabels.contains(label($0)) }
            if sends.count == 1, attachments.count == 1 { found = (group, sends[0], members); break }
            parent = element(attribute(group, kAXParentAttribute))
        }
        guard let (composer, send, members) = found else {
            DiagnosticLog.shared.record("desktop.composerUnavailable")
            throw DesktopError.composer
        }
        let busy = nodes.contains { role($0) == "AXButton" && stopLabels.contains(label($0)) }
        // Attachment chips/images or unknown controls are conservatively rejected.
        let knownButtons = sendLabels.union(attachLabels).union(stopLabels).union(["model", "tools", "模型", "工具"])
        let inputNodes = try descendants(input, limit: 180)
        let hasAttachments = members.contains { node in
            if inputNodes.contains(where: { CFEqual($0, node) }) { return false }
            return ["AXImage", "AXLink"].contains(role(node))
                || (role(node) == "AXButton" && !knownButtons.contains(label(node)))
                || (role(node) == "AXStaticText" && !knownButtons.contains(label(node)))
        }
        let revision = "\(CFHash(window)):\(CFHash(input)):\(CFHash(send))"
        let snapshot = DesktopSnapshot(targetID: identityMatches ? target.id : nil, revision: revision, draft: draft,
                                       hasAttachments: hasAttachments, busy: busy)
        return View(window: window, input: input, composer: composer, send: send, nodes: nodes, snapshot: snapshot)
    }

    private func occurrences(message: String, view: View) -> Int {
        let composerNodes = (try? descendants(view.composer, limit: 180)) ?? []
        return view.nodes.filter { node in
            role(node) == "AXStaticText" && (attribute(node, kAXValueAttribute) as? String) == message
                && !composerNodes.contains { CFEqual(node, $0) }
        }.count
    }

    private func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &result) == .success else { return nil }
        return result
    }
    private func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
    private func role(_ node: AXUIElement) -> String { attribute(node, kAXRoleAttribute) as? String ?? "" }
    private func label(_ node: AXUIElement) -> String {
        let strings = [kAXTitleAttribute, kAXDescriptionAttribute, "AXHelp"]
            .compactMap { attribute(node, $0) as? String }.filter { !$0.isEmpty }
        return strings.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }
    private func descendants(_ root: AXUIElement, limit: Int) throws -> [AXUIElement] {
        var queue = [root]
        var result = [AXUIElement]()
        var visited = Set<CFHashCode>()
        while !queue.isEmpty {
            let node = queue.removeLast()
            guard visited.insert(CFHash(node)).inserted else { continue }
            guard result.count < limit else { throw DesktopError.composer }
            if (attribute(node, "AXHidden") as? Bool) == true { continue }
            result.append(node)
            if let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: children) }
        }
        return result
    }
}

/// Only active window/document URLs enter this function, never sidebar links or titles.
enum CodexDesktopIdentity {
    static func matches(documents: [String], targetID: UUID) -> Bool {
        documentIDs(documents: documents) == [targetID]
    }

    static func documentIDs(documents: [String]) -> Set<UUID> {
        Set(documents.compactMap { document -> UUID? in
            if let target = try? Target(link: document) { return target.id }
            guard let url = URL(string: document), url.query == nil, url.fragment == nil else { return nil }
            let parts = url.pathComponents
            guard parts.count >= 2, let id = UUID(uuidString: parts.last ?? "") else { return nil }
            return ["threads", "thread", "local"].contains(parts[parts.count - 2]) ? id : nil
        })
    }
}
