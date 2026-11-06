import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let model = AssistantModel()
    private let notice = TransientNotice()

    func applicationDidFinishLaunching(_ notification: Notification) {
        DiagnosticLog.shared.record("app.started", fields: ["build": "diagnostics-v11-shortcut-picker", "shortcutMode": "automatic"])
        NSApp.applicationIconImage = Q2CIcon.applicationImage()
        installMainMenu()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Q2CIcon.menuImage()
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item

        model.showPopover = { [weak self] in self?.showPopover() }
        model.hidePopover = { [weak self] in self?.popover?.performClose(nil) }
        model.showNotice = { [weak self] in self?.notice.show($0) }
        model.enableShortcut()
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        let popover = makePopover()
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        let popover = makePopover()
        guard !popover.isShown else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func makePopover() -> NSPopover {
        if let popover { return popover }
        let popover = NSPopover()
        popover.behavior = .transient
        let controller = NSHostingController(rootView: AssistantView(model: model))
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        self.popover = popover
        return popover
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model.stop() }

    private func installMainMenu() {
        let mainMenu = NSMenu(title: "Q2C")

        let appMenuItem = NSMenuItem()
        appMenuItem.title = "Q2C"
        let appMenu = NSMenu(title: "Q2C")
        let quitItem = appMenu.addItem(withTitle: "退出 Q2C", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        mainMenu.addItem(appMenuItem)
        mainMenu.setSubmenu(appMenu, for: appMenuItem)

        let fileMenuItem = NSMenuItem()
        fileMenuItem.title = "文件"
        let fileMenu = NSMenu(title: "文件")
        let closeItem = NSMenuItem(title: "关闭窗口", action: #selector(closePopover(_:)), keyEquivalent: "w")
        closeItem.keyEquivalentModifierMask = [.command]
        closeItem.target = self
        fileMenu.addItem(closeItem)
        mainMenu.addItem(fileMenuItem)
        mainMenu.setSubmenu(fileMenu, for: fileMenuItem)

        let editMenuItem = NSMenuItem()
        editMenuItem.title = "编辑"
        let editMenu = NSMenu(title: "编辑")
        let cutItem = editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        cutItem.keyEquivalentModifierMask = [.command]
        let copyItem = editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        copyItem.keyEquivalentModifierMask = [.command]
        let pasteItem = editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        pasteItem.keyEquivalentModifierMask = [.command]
        editMenu.addItem(.separator())
        let selectAllItem = editMenu.addItem(withTitle: "全选", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        selectAllItem.keyEquivalentModifierMask = [.command]
        mainMenu.addItem(editMenuItem)
        mainMenu.setSubmenu(editMenu, for: editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func closePopover(_ sender: Any?) {
        popover?.performClose(sender)
    }
}

@main
enum Q2CMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}
