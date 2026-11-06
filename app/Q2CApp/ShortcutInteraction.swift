import AppKit
import SwiftUI
import Q2CCore

enum ShortcutTargets {
    static func ordered(_ profiles: [ForwardProfile]) -> [ForwardProfile] {
        let valid = profiles.filter { (try? $0.target()) != nil }
        return valid.filter(\.isFavorite) + valid.filter { !$0.isFavorite }
    }
}

@MainActor
protocol ShortcutResolving: AnyObject {
    func resolve(profiles: [ForwardProfile], revision: Int) async throws -> ForwardProfile?
    func close()
}

@MainActor
final class ShortcutInteraction: ObservableObject, ShortcutResolving {
    @Published var highlighted = 0
    @Published private(set) var clickProtectionAvailable = false
    private var clickGuard: PickerClickGuard?
    private let shortcut: Q2CCore.KeyboardShortcut
    private let started = ProcessInfo.processInfo.systemUptime
    private let sourcePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    private var tracker: Task<Void, Never>?
    private var panel: NSPanel?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var chosen: UUID?
    private var restoreSourceOnClose = true
    private var finished = false
    private var escaped = false

    var shortcutKeyLabel: String { shortcut.keyLabel }
    var shortcutDisplayName: String { shortcut.displayName }

    init(shortcut: Q2CCore.KeyboardShortcut) {
        self.shortcut = shortcut
        tracker = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                if self.keyDown(53) { self.escaped = true }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    func close() {
        clickGuard?.stopAfterRelease()
        clickGuard = nil
        tracker?.cancel()
        tracker = nil
        for monitor in [localMonitor, globalMonitor, keyMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
        localMonitor = nil; globalMonitor = nil; keyMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        let hadPanel = panel != nil
        panel?.orderOut(nil)
        panel = nil
        if hadPanel, restoreSourceOnClose {
            PickerFocusRestoration.restore(sourcePID: sourcePID,
                ownPID: ProcessInfo.processInfo.processIdentifier,
                frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
                activate: { NSRunningApplication(processIdentifier: $0)?.activate(options: []) ?? false })
        }
    }

    private func keyDown(_ code: UInt32) -> Bool {
        CGEventSource.keyState(.hidSystemState, key: CGKeyCode(code))
    }

    private var modifiersHeld: Bool {
        let flags = CGEventSource.flagsState(.hidSystemState)
        var expected: CGEventFlags = []
        if shortcut.modifiers.contains(.command) { expected.insert(.maskCommand) }
        if shortcut.modifiers.contains(.option) { expected.insert(.maskAlternate) }
        if shortcut.modifiers.contains(.control) { expected.insert(.maskControl) }
        if shortcut.modifiers.contains(.shift) { expected.insert(.maskShift) }
        return expected.isEmpty ? keyDown(shortcut.keyCode) : !flags.intersection(expected).isEmpty
    }

    /// Resolve only after a successful source copy; never read the payload.
    func resolve(profiles: [ForwardProfile], revision: Int) async throws -> ForwardProfile? {
        defer { close() }
        try Task.checkCancellation()
        guard !escaped, NSPasteboard.general.changeCount == revision,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == sourcePID else { return nil }
        let valid = ShortcutTargets.ordered(profiles)
        guard !valid.isEmpty else { throw AssistantError.invalidTarget }
        highlighted = 0
        // A quick release uses the same default selection, without flashing a chooser.
        if !modifiersHeld { return valid[0] }
        show(profiles: valid, allProfiles: profiles)
        var previousTrigger = keyDown(shortcut.keyCode)
        while !finished {
            try Task.checkCancellation()
            guard !escaped, NSPasteboard.general.changeCount == revision,
                  ProcessInfo.processInfo.systemUptime - started < 60 else { return nil }
            do {
                // Check release before cycling, so a final key transition cannot change the chosen row.
                if !modifiersHeld {
                    restoreSourceOnClose = false
                    return valid[highlighted]
                }
                let trigger = keyDown(shortcut.keyCode)
                if trigger && !previousTrigger {
                    let backwards = CGEventSource.flagsState(.hidSystemState).contains(.maskShift)
                    highlighted = (highlighted + (backwards ? valid.count - 1 : 1)) % valid.count
                }
                previousTrigger = trigger
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let selected = valid.first(where: { $0.id == chosen })
        if selected != nil { restoreSourceOnClose = false }
        return selected
    }

    private func show(profiles: [ForwardProfile], allProfiles: [ForwardProfile]) {
        let panel = PickerPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let controller = NSHostingController(rootView: ShortcutPicker(interaction: self, profiles: profiles, allProfiles: allProfiles) { [weak self] id in
            self?.chosen = id
            self?.finished = true
        })
        panel.contentViewController = controller
        let size = controller.view.fittingSize
        panel.setContentSize(size)
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        }
        self.panel = panel
        let clickGuard = PickerClickGuard(contains: { [weak panel] point in
            panel?.frame.contains(point) == true
        }, cancel: { [weak self] in
            self?.chosen = nil
            self?.finished = true
        }, unavailable: { [weak self] in
            self?.clickProtectionAvailable = false
            DiagnosticLog.shared.record("picker.clickProtectionDisabled")
        })
        clickProtectionAvailable = clickGuard.start()
        self.clickGuard = clickGuard
        DiagnosticLog.shared.record("picker.clickProtection", fields: ["enabled": String(clickProtectionAvailable)])
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                 object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finished = true }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.window !== self?.panel { self?.finished = true }
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.finished = true }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            // This panel has no text entry. Consume navigation keys instead of editing settings.
            nil
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
}

private struct ShortcutPicker: View {
    @AppStorage("Q2C.interfaceEnglish") private var isEnglish = false

    private func text(_ chinese: String, _ english: String) -> String {
        isEnglish ? english : chinese
    }
    @ObservedObject var interaction: ShortcutInteraction
    let profiles: [ForwardProfile]
    let allProfiles: [ForwardProfile]
    let select: (UUID?) -> Void
    private func displayName(_ profile: ForwardProfile) -> String {
        let note = profile.note.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = (allProfiles.firstIndex(where: { $0.id == profile.id }) ?? 0) + 1
        return note.isEmpty ? text("配置\(number)", "Profile \(number)") : profile.note
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(nsImage: Q2CIcon.menuImage())
                    .accessibilityHidden(true)
                Text(text("按 \(interaction.shortcutKeyLabel) 切换 · 松开 \(interaction.shortcutDisplayName) 转交",
                          "Press \(interaction.shortcutKeyLabel) to switch · Release \(interaction.shortcutDisplayName) to forward"))
                    .font(.headline)
                Spacer()
                Button { select(nil) } label: {
                    Image(systemName: "xmark").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(text("取消转交", "Cancel forwarding"))
                .help(text("取消转交", "Cancel forwarding"))
            }
            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 8) {
            ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                Button { select(profile.id) } label: {
                    HStack(spacing: 10) {
                        if profile.isFavorite { Image(systemName: "star.fill") }
                        Text(displayName(profile)).font(.headline).lineLimit(1)
                            .help(displayName(profile))
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 40)
                    .background(interaction.highlighted == index ? Color.accentColor.opacity(0.25) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .id(profile.id)
                .onHover { if $0 { interaction.highlighted = index } }
            }
                }
            }
            .frame(height: min(CGFloat(profiles.count) * 40 + CGFloat(max(0, profiles.count - 1)) * 8,
                               max(100, (NSScreen.main?.visibleFrame.height ?? 780) - 180)))
            .onChange(of: interaction.highlighted) { _, index in
                proxy.scrollTo(profiles[index].id, anchor: .center)
            }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(width: 410)
        .background {
            Color.clear.contentShape(Rectangle()).onTapGesture { select(nil) }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Restore only while Q2C still owns the foreground; never take focus from another app.
@MainActor
enum PickerFocusRestoration {
    static func restore(sourcePID: pid_t?, ownPID: pid_t,
                        frontmostPID: () -> pid_t?, activate: (pid_t) -> Bool) {
        guard let sourcePID, sourcePID != ownPID, frontmostPID() == ownPID else { return }
        let restored = activate(sourcePID)
        DiagnosticLog.shared.record("picker.sourceRestoreRequested", fields: [
            "sourcePID": String(sourcePID), "activationAccepted": String(restored)
        ])
    }
}
