import Foundation

public enum AssistantError: Error, Equatable, LocalizedError, Sendable {
    case invalidTarget, invalidLink, noText, tooLarge, invalidText, invalidShortcut, reservedShortcut
    case pendingCapture
    case adapterUnavailable, unverifiedTarget, unreadableDraft, existingDraft, busy, duplicateShortcut
    case changedState, invalidTransition, uncertainSubmission

    public var errorDescription: String? {
        switch self {
        case .invalidTarget: "请填写有效的目标任务 UUID。"
        case .invalidLink: "请填写完整的 Codex 任务链接，格式为 codex://threads/任务ID，不含额外参数。"
        case .noText: "没有可用的文本内容。"
        case .tooLarge: "文本超过 64 KiB，请分段处理。"
        case .invalidText: "文本含有 NUL 字符，无法处理。"
        case .invalidShortcut: "快捷键必须包含至少一个修饰键（⌘、⌥、⌃、⇧）和一个普通按键。"
        case .reservedShortcut: "该按键组合保留给系统操作或用于取消，请选择其他快捷键。"
        case .pendingCapture: "当前内容仍在处理，无法替换。"
        case .adapterUnavailable: "自动填入与提交暂不可用。"
        case .unverifiedTarget: "无法确认当前窗口属于目标任务，已停止。"
        case .unreadableDraft: "无法读取输入框或附件状态，已停止。"
        case .existingDraft: "目标任务已有草稿或附件，已停止。"
        case .busy: "目标任务正在处理其他消息，已停止。"
        case .duplicateShortcut: "每组配置的快捷键必须不同，请修改重复的快捷键。"
        case .changedState: "任务或输入框状态发生变化，已停止。"
        case .invalidTransition: "当前状态不允许此操作。"
        case .uncertainSubmission: "提交结果待核实，请先查看目标任务，不能直接重试。"
        }
    }
}

public struct Target: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let navigationURL: URL?

    public init(link: String) throws {
        let (id, url) = try Self.parseLink(link)
        self.id = id
        self.name = "Codex 目标任务"
        self.navigationURL = url
    }

    private static func parseLink(_ link: String) throws -> (UUID, URL) {
        let value = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: value),
              parts.scheme == "codex", parts.host == "threads",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil,
              parts.percentEncodedPath == parts.path,
              !value.contains(where: { $0.isWhitespace }) else { throw AssistantError.invalidLink }
        let path = parts.path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 2, path[0].isEmpty,
              let id = UUID(uuidString: String(path[1])), let url = parts.url else {
            throw AssistantError.invalidLink
        }
        return (id, url)
    }

    /// Links are navigation hints, never proof of the active task's identity.
    /// No URL template is generated: the user must supply the original task link.
    public init(id: String, name: String, link: String = "") throws {
        guard let uuid = UUID(uuidString: id.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw AssistantError.invalidTarget
        }
        self.id = uuid
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if link.isEmpty {
            navigationURL = nil
        } else {
            let (linkedID, url) = try Self.parseLink(link)
            guard linkedID == uuid else { throw AssistantError.invalidLink }
            navigationURL = url
        }
    }
}

public enum MessageWrapper {
    public static let maxUTF8Bytes = 64 * 1024
    public static let defaultHeader = ""

    public static func validateAffixes(header: String, footer: String) throws {
        guard header.utf8.count + footer.utf8.count <= maxUTF8Bytes else { throw AssistantError.tooLarge }
        guard !header.contains("\0"), !footer.contains("\0") else { throw AssistantError.invalidText }
    }

    public static func wrap(_ raw: String, header: String = defaultHeader, footer: String = "") throws -> String {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AssistantError.noText
        }
        guard raw.utf8.count <= maxUTF8Bytes else { throw AssistantError.tooLarge }
        guard !raw.contains("\0") else { throw AssistantError.invalidText }
        try validateAffixes(header: header, footer: footer)
        return (header.isEmpty ? "" : header + "\n") + raw + (footer.isEmpty ? "" : "\n" + footer)
    }
}

public struct Capture: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let target: Target
    public let message: String
}

/// Capacity one: never replaces an unsent preview. Text is retained only in memory.
public struct CaptureBuffer: Sendable {
    public private(set) var current: Capture?

    public init() {}

    @discardableResult
    public mutating func capture(text: String?, target: Target,
                                 header: String = MessageWrapper.defaultHeader, footer: String = "") throws -> Capture {
        guard current == nil else { throw AssistantError.pendingCapture }
        guard let text else { throw AssistantError.noText }
        let capture = Capture(id: UUID(), target: target,
                              message: try MessageWrapper.wrap(text, header: header, footer: footer))
        current = capture
        return capture
    }

    public mutating func discard() { current = nil }
}
