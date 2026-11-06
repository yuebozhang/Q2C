import AppKit
import SwiftUI
import Q2CCore

struct AssistantView: View {
    @ObservedObject var model: AssistantModel
    @AppStorage("Q2C.interfaceEnglish") private var isEnglish = false
    @State private var pendingSaveTask: Task<Void, Never>?
    @State private var profilePendingDeletion: UUID?
    @State private var measuredHeight: CGFloat = 220
    @State private var maximumHeight: CGFloat = 700

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 14).frame(height: 40)
                .background(heightMeasurement)
            Divider()
            if model.isChoosingTarget {
                targetChooser
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach($model.profiles) { profile in
                            if profile.wrappedValue.id != model.profiles.first?.id {
                                Divider()
                            }
                            profileBlock(profile: profile)
                                .padding(.horizontal, 14)
                        }

                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .background(heightMeasurement)
                }
            }

        }
        .frame(width: 600, height: min(measuredHeight + 1, maximumHeight), alignment: .top)
        .onPreferenceChange(PanelContentHeight.self) { measuredHeight = $0 }
        .onAppear {
            let screen = NSApp.keyWindow?.screen ?? NSScreen.main
            maximumHeight = max(100, (screen?.visibleFrame.height ?? 780) - 40)
        }
        .background(.regularMaterial)
        .onChange(of: model.profiles) { _, _ in scheduleAutoSave() }
        .onChange(of: model.isBusy) { _, busy in
            if !busy { scheduleAutoSave() }
        }
        .alert(text("删除这组配置？", "Delete profile?"), isPresented: Binding(
            get: { profilePendingDeletion != nil },
            set: { if !$0 { profilePendingDeletion = nil } }
        )) {
            Button(text("取消", "Cancel"), role: .cancel) { profilePendingDeletion = nil }
            Button(text("删除", "Delete"), role: .destructive) {
                if let id = profilePendingDeletion { model.removeProfile(id) }
                profilePendingDeletion = nil
            }
        } message: {
            Text(text("将删除这组配置的目标链接和备注。此操作无法撤销。", "Delete this target and note? This cannot be undone."))
        }
        .onDisappear {
            model.cancelTargetChoice()
            flushAutoSave()
        }
    }

    private func text(_ chinese: String, _ english: String) -> String {
        isEnglish ? english : chinese
    }

    private var heightMeasurement: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: PanelContentHeight.self, value: geometry.size.height)
        }
    }

    private var targetChooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text("选择目标任务", "Choose target")).font(.headline).background(heightMeasurement)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(model.targetChoices.enumerated()), id: \.element.id) { index, profile in
                        Button { model.chooseTarget(profile.id) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(text("配置 \(index + 1)", "Profile \(index + 1)")).font(.headline)
                                Text(profile.targetLink.isEmpty ? text("未填写任务链接", "No target link") : profile.targetLink)
                                    .font(.caption).lineLimit(2)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .disabled((try? profile.target()) == nil)
                    }
                }
                .background(heightMeasurement)
            }
            Button(text("取消", "Cancel"), action: model.cancelTargetChoice).keyboardShortcut(.cancelAction)
                .background(heightMeasurement)
        }
        .padding(14)
        .transformPreference(PanelContentHeight.self) { $0 += 52 } // Padding and two stack gaps.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(text("选中内容按快捷键转交到 Codex 对话线程", "Use the shortcut to forward selected content to a Codex conversation thread"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
            Spacer()
            Button(isEnglish ? "CN" : "EN") { isEnglish.toggle() }
                .buttonStyle(.plain)
                .frame(minWidth: 24, minHeight: 24)
                .help(isEnglish ? "切换到中文" : "Switch to English")
                .accessibilityLabel(isEnglish ? "切换到中文" : "Switch to English")
            ShortcutRecorder(shortcut: $model.profiles[0].shortcut,
                             isEnabled: !model.isBusy, isEnglish: isEnglish)
                .frame(width: 146, height: 28)
            Button(text("新建配置", "Add profile"), systemImage: "plus", action: model.addProfile)
                .labelStyle(.iconOnly)
                .font(.system(size: 16, weight: .regular))
                .help(text("新建配置", "Add profile"))
                .buttonStyle(.plain)
                .frame(width: 24, height: 24)
                .disabled(!model.canAddProfile || model.isChoosingTarget)
            Button(text("退出", "Quit"), systemImage: "power", action: { NSApp.terminate(nil) })
                .labelStyle(.iconOnly)
                .font(.system(size: 16, weight: .regular))
                .buttonStyle(.plain)
                .frame(width: 24, height: 24)
                .help(text("退出 Q2C", "Quit Q2C"))
        }
    }

    private func profileBlock(profile: Binding<ForwardProfile>) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                TextField(profilePlaceholder(profile.wrappedValue.id), text: profile.note)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .accessibilityLabel(text("备注，可选", "Note, optional"))
                    .modifier(FullFieldHover(content: profile.wrappedValue.note, label: text("配置备注", "Profile note")))
                    .disabled(model.isBusy)
                TextField(text("请输入深度链接（必填）", "Deep link (required)"), text: profile.targetLink)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(text("Codex 深度链接，必填", "Codex deep link, required"))
                    .modifier(FullFieldHover(content: profile.wrappedValue.targetLink, label: text("深度链接", "Deep link")))
                    .disabled(model.isBusy)
                Button {
                    model.favoriteProfile(profile.wrappedValue.id)
                } label: {
                    Image(systemName: profile.wrappedValue.isFavorite ? "star.fill" : "star")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(profile.wrappedValue.isFavorite ? Color.yellow : Color.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(profile.wrappedValue.isFavorite ? text("取消默认转交配置", "Clear default target") : text("设为默认转交配置", "Set default target"))
                .help(profile.wrappedValue.isFavorite ? text("取消标星", "Unstar") : text("设为默认转交配置", "Set default target"))
                .disabled(model.isBusy)
                Button {
                    profilePendingDeletion = profile.wrappedValue.id
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(text("删除这组配置", "Delete profile"))
                .help(text("删除这组配置", "Delete profile"))
                .disabled(model.isBusy)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .frame(height: 45)

            if !profile.wrappedValue.targetLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               (try? profile.wrappedValue.target()) == nil {
                Text(text("请填写完整的 codex://threads/任务ID 链接", "Use a full codex://threads/task-ID link"))
                    .font(.caption2).foregroundStyle(.orange)
            }


        }

    }

    private func profilePlaceholder(_ id: UUID) -> String {
        text("配置\((model.profiles.firstIndex(where: { $0.id == id }) ?? 0) + 1)",
             "Profile \((model.profiles.firstIndex(where: { $0.id == id }) ?? 0) + 1)")
    }

    private func scheduleAutoSave() {
        pendingSaveTask?.cancel()
        guard !model.isBusy else { return }
        pendingSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, model.hasUnsavedSettings else { return }
            model.saveSettings()
        }
    }

    private func flushAutoSave() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        guard !model.isBusy, model.hasUnsavedSettings else { return }
        model.saveSettings()
    }
}

private struct PanelContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}

private struct FullFieldHover: ViewModifier {
    let content: String
    let label: String
    @State private var tooltip = FieldTooltip()
    func body(content view: Content) -> some View {
        view.onHover { inside in
            if inside { tooltip.schedule("\(label):\n\(content)") } else { tooltip.close() }
        }
        .onChange(of: content) { _, value in
            if tooltip.isHovering { tooltip.schedule("\(label):\n\(value)") }
        }
        .onChange(of: label) { _, _ in tooltip.close() }
        .onDisappear { tooltip.close() }
    }
}

@MainActor
private final class FieldTooltip {
    private var task: Task<Void, Never>?
    private var panel: NSPanel?
    private(set) var isHovering = false
    func schedule(_ text: String) {
        close()
        isHovering = true
        guard !text.isEmpty else { return }
        task = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let self, self.isHovering else { return }
            let cursor = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
            let controller = NSHostingController(rootView:
                Text(text).font(.caption).foregroundStyle(.primary)
                    .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                    .frame(width: 300, alignment: .leading).padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6)))
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .popUpMenu
            panel.ignoresMouseEvents = true
            panel.hasShadow = true
            panel.contentViewController = controller
            let size = controller.view.fittingSize
            panel.setContentSize(size)
            let frame = screen?.visibleFrame ?? .zero
            panel.setFrameOrigin(NSPoint(x: max(frame.minX, min(cursor.x + 12, frame.maxX - size.width)),
                                         y: max(frame.minY, cursor.y - 18 - size.height)))
            self.panel = panel
            panel.orderFrontRegardless()
        }
    }
    func close() {
        isHovering = false
        task?.cancel()
        task = nil
        panel?.orderOut(nil)
        panel = nil
    }
}
