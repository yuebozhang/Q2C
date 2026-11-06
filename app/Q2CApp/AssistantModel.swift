import AppKit
import Combine
import Q2CCore

@MainActor
final class AssistantModel: ObservableObject {
    @Published var profiles = [ForwardProfile(isFavorite: true)]
    @Published private(set) var status = "填写 Codex 深度链接后，选中内容并按快捷键即可粘贴到 Codex。"
    @Published private(set) var isError = false
    @Published private(set) var shortcutEnabled = false
    @Published private(set) var savedProfiles = [ForwardProfile()]
    @Published private(set) var targetChoices = [ForwardProfile]()
    @Published private(set) var isPasting = false
    @Published private(set) var isReading = false
    var isChoosingTarget: Bool { pendingContent != nil }
    var isBusy: Bool { isReading || isChoosingTarget || isPasting }
    var showPopover: (() -> Void)?
    var hidePopover: (() -> Void)?
    var showNotice: ((String) -> Void)?

    // Compatibility accessors keep the existing preview model tests and migration callers intact.
    var settings: LocalConfiguration {
        get { profiles.first?.localConfiguration ?? LocalConfiguration() }
        set {
            let id = profiles.first?.id ?? UUID()
            let profile = ForwardProfile(id: id, targetLink: newValue.targetLink, shortcut: newValue.shortcut,
                                         messageHeader: newValue.messageHeader, messageFooter: newValue.messageFooter,
                                         isFavorite: profiles.first?.isFavorite ?? true, note: profiles.first?.note ?? "")
            if profiles.isEmpty { profiles = [profile] } else { profiles[0] = profile }
        }
    }
    var savedSettings: LocalConfiguration { savedProfiles.first?.localConfiguration ?? LocalConfiguration() }
    var showWindow: (() -> Void)? {
        get { showPopover }
        set { showPopover = newValue }
    }

    private var shortcuts: [UUID: GlobalShortcut] = [:]
    private let paster: any ClipboardPasting
    private var pendingContent: CopiedContent?
    private var inputTask: Task<Void, Never>?
    private var pasteTask: Task<Void, Never>?
    private let store: ConfigurationStore
    private let selection: any SelectionAccess
    private var traceID = UUID().uuidString
    private var triggerStarted = ProcessInfo.processInfo.systemUptime

    init(store: ConfigurationStore? = nil, selection: any SelectionAccess = SystemSelection(),
         paster: any ClipboardPasting = CodexClipboardPaster()) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Q2C", isDirectory: true)
        self.store = store ?? ConfigurationStore(directory: directory, legacyDirectory: directory.deletingLastPathComponent().appendingPathComponent("SmacqSSS", isDirectory: true))
        self.selection = selection
        self.paster = paster
        do {
            profiles = try self.store.loadProfiles()
            savedProfiles = profiles
        } catch {
            report("本机配置无法读取，请重新填写并保存。", error: true)
        }
    }

    var hasUnsavedSettings: Bool { profiles != savedProfiles }
    var configurationPath: String { store.fileURL.path }
    var canRemoveProfiles: Bool { !isBusy }
    static let maximumProfiles = 8
    var canAddProfile: Bool {
        !isBusy && profiles.count < Self.maximumProfiles && !profiles.contains { $0.targetLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func saveSettings() {
        do {
            guard !isBusy else { throw AssistantError.pendingCapture }
            try persistSettings()
            enableShortcut()
        } catch { report(error.localizedDescription, error: true) }
    }

    func addProfile() {
        guard canAddProfile else { return }
        let occupied = Set(profiles.map { "\($0.shortcut.keyCode):\($0.shortcut.modifiers.rawValue)" })
        let keyCode: UInt32 = 8
        let choices: [KeyboardShortcut] = [
            .standard,
            KeyboardShortcut(keyCode: keyCode, modifiers: [.command, .shift], keyLabel: "C"),
            KeyboardShortcut(keyCode: keyCode, modifiers: [.command, .control], keyLabel: "C"),
            KeyboardShortcut(keyCode: keyCode, modifiers: [.command, .shift, .option], keyLabel: "C"),
            KeyboardShortcut(keyCode: keyCode, modifiers: [.command, .control, .option], keyLabel: "C"),
            KeyboardShortcut(keyCode: keyCode, modifiers: [.command, .control, .shift], keyLabel: "C"),
            KeyboardShortcut(keyCode: keyCode, modifiers: .all, keyLabel: "C"),
            KeyboardShortcut(keyCode: keyCode, modifiers: [.control, .option], keyLabel: "C")
        ]
        let shortcut = choices.first { !occupied.contains("\($0.keyCode):\($0.modifiers.rawValue)") } ?? .standard
        profiles.append(ForwardProfile(shortcut: shortcut))
        report("已添加转发配置。请填写深度链接并保存。")
    }

    func removeProfile(_ id: UUID) {
        guard canRemoveProfiles, let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        if profiles.count == 1 {
            // Keep one editable slot for the settings and global shortcut binding.
            profiles[index] = ForwardProfile(shortcut: profiles[index].shortcut)
        } else {
            profiles.remove(at: index)
        }
        profiles = ForwardProfile.normalizedFavorites(profiles)
        report("已删除转发配置。将自动保存。")
    }

    func favoriteProfile(_ id: UUID) {
        guard !isBusy, profiles.contains(where: { $0.id == id }) else { return }
        let shouldFavorite = profiles.first(where: { $0.id == id })?.isFavorite != true
        profiles = profiles.map { profile in
            var result = profile
            result.isFavorite = shouldFavorite && profile.id == id
            return result
        }
    }

    private func persistSettings() throws {
        try store.saveProfiles(profiles)
        savedProfiles = profiles
        // Replace registrations after configuration changes.
        disableShortcut()
    }

    func copySelectedContent(profileID: UUID? = nil, useFavorite: Bool = true, interaction: (any ShortcutResolving)? = nil) async {
        guard !isBusy else { return }
        isReading = true
        defer { isReading = false; interaction?.close() }
        let sourceProfiles = profiles
        traceID = UUID().uuidString
        triggerStarted = ProcessInfo.processInfo.systemUptime
        DiagnosticLog.shared.record("input.triggered", trace: traceID)
        do {
            DiagnosticLog.shared.record("input.copyStarted", trace: traceID, fields: ["pollMs": "50", "timeoutMs": "400"])
            let content = try await selection.read()
            try Task.checkCancellation()
            DiagnosticLog.shared.record("input.copyReady", trace: traceID, fields: [
                "elapsedMs": String(Int((ProcessInfo.processInfo.systemUptime - triggerStarted) * 1000)),
                "copyUpdateMs": String(Int((content.updateObservedAt - content.copyRequestedAt) * 1000))
            ])
            guard !sourceProfiles.isEmpty else { throw AssistantError.invalidTarget }
            if let interaction {
                if let profile = try await interaction.resolve(profiles: sourceProfiles, revision: content.revision) {
                    try startPaste(content: content, profile: profile)
                } else { report("已取消；来源复制的内容保留在剪贴板。") }
            } else if let profileID {
                guard let profile = sourceProfiles.first(where: { $0.id == profileID }) else { throw AssistantError.invalidTarget }
                try startPaste(content: content, profile: profile)
            } else if useFavorite, let favorite = sourceProfiles.first(where: { $0.isFavorite }) {
                try startPaste(content: content, profile: favorite)
            } else if sourceProfiles.count == 1 {
                try startPaste(content: content, profile: sourceProfiles[0])
            } else {
                // Freeze the clipboard revision and configuration before changing focus.
                pendingContent = content
                targetChoices = sourceProfiles
                report("请选择要粘贴到的任务。")
                showPopover?()
            }
        } catch is CancellationError {
            report("复制已取消。")
        } catch { inputFailed(error) }
    }

    func chooseTarget(_ id: UUID) {
        guard let content = pendingContent, let profile = targetChoices.first(where: { $0.id == id }) else { return }
        pendingContent = nil
        targetChoices = []
        do { try startPaste(content: content, profile: profile) }
        catch { inputFailed(error) }
    }

    func cancelTargetChoice() {
        guard isChoosingTarget else { return }
        pendingContent = nil
        targetChoices = []
        report("已取消；来源复制的内容保留在剪贴板。")
        hidePopover?()
    }

    private func startPaste(content: CopiedContent, profile: ForwardProfile) throws {
        let target = try profile.target()
        DiagnosticLog.shared.record("input.targetResolved", trace: traceID)
        isPasting = true
        report("复制已更新，正在打开目标任务并原样粘贴……")
        hidePopover?()
        let trace = traceID
        pasteTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.paster.paste(target: target, content: content, header: "", footer: "", traceID: trace)
                DiagnosticLog.shared.record("input.pasteRequested", trace: trace, fields: [
                    "elapsedMs": String(Int((ProcessInfo.processInfo.systemUptime - self.triggerStarted) * 1000))
                ])
                self.report("已请求粘贴到 Codex，请查看输入框并手动发送。")
            } catch is CancellationError {
                self.report("粘贴已取消。")
            } catch {
                self.report(error.localizedDescription, error: true)
                self.showNotice?(error.localizedDescription)
                DiagnosticLog.shared.record("paste.failed", trace: trace, fields: ["errorType": String(reflecting: type(of: error))])
            }
            self.isPasting = false
            self.pasteTask = nil
        }
    }

    private func inputFailed(_ error: Error) {
        report(error.localizedDescription, error: true)
        showNotice?(error.localizedDescription)
        var fields = ["errorType": String(reflecting: type(of: error)),
                      "elapsedMs": String(Int((ProcessInfo.processInfo.systemUptime - triggerStarted) * 1000))]
        if let failure = error as? TextInputIssue { fields["reason"] = String(describing: failure) }
        DiagnosticLog.shared.record("input.rejected", trace: traceID, fields: fields)
    }

    func enableShortcut() {
        DiagnosticLog.shared.record("shortcut.enableRequested")
        do {
            guard !isBusy else { throw AssistantError.pendingCapture }
            guard let profile = profiles.first else { throw AssistantError.invalidTarget }
            try profile.shortcut.validate()
            guard !profile.shortcut.isReservedSystemShortcut else { throw AssistantError.reservedShortcut }
            if hasUnsavedSettings { try persistSettings() }
            guard let activeProfile = savedProfiles.first else { throw AssistantError.invalidTarget }
            let registration = GlobalShortcut()
            do {
                try registration.enable(shortcut: activeProfile.shortcut) { [weak self] in
                    guard let self, !self.isBusy, self.inputTask == nil else { return }
                    let interaction = ShortcutInteraction(shortcut: activeProfile.shortcut)
                    self.inputTask = Task { @MainActor [weak self] in
                        await self?.copySelectedContent(interaction: interaction)
                        self?.inputTask = nil
                    }
                }
            } catch {
                registration.disable()
                throw error
            }
            shortcuts = [activeProfile.id: registration]
            shortcutEnabled = true
            DiagnosticLog.shared.record("shortcut.enabled", fields: ["count": "1"])
            report("快捷键已就绪，选中内容后按快捷键即可转发。")
        } catch {
            DiagnosticLog.shared.record("shortcut.enableFailed", fields: ["errorType": String(reflecting: type(of: error))])
            report(error.localizedDescription, error: true)
        }
    }

    func disableShortcut() {
        DiagnosticLog.shared.record("shortcut.disabled")
        shortcuts.values.forEach { $0.disable() }
        shortcuts.removeAll()
        shortcutEnabled = false
    }

    func stop() {
        disableShortcut()
        inputTask?.cancel()
        pasteTask?.cancel()
        pendingContent = nil
        targetChoices = []
    }

    private func report(_ text: String, error: Bool = false) {
        status = text
        isError = error
    }
}
