import AppKit

@MainActor
final class TransientNotice {
    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?

    func show(_ text: String) {
        dismissal?.cancel()
        panel?.close()
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.alignment = .left
        let font = label.font!
        let maximumTextWidth = min(440, max(120, (NSScreen.main?.visibleFrame.width ?? 800) - 100))
        let textWidth = max(1, min(maximumTextWidth, ceil((text as NSString).size(withAttributes: [.font: font]).width)))
        let textBounds = (text as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        label.preferredMaxLayoutWidth = textWidth + 4
        label.maximumNumberOfLines = 0
        let size = NSSize(width: textWidth + 74, height: max(20, ceil(textBounds.height) + 4) + 24)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.autoresizingMask = [.width, .height]
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        let icon = NSImageView(image: Q2CIcon.menuImage())
        icon.contentTintColor = .labelColor
        icon.setAccessibilityElement(false)
        let content = NSStackView(views: [icon, label])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -20),
            content.centerYAnchor.constraint(equalTo: background.centerYAnchor)
        ])
        panel.contentView = background
        panel.center()
        panel.orderFrontRegardless()
        self.panel = panel
        dismissal = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.panel?.close()
            self?.panel = nil
        }
    }
}
