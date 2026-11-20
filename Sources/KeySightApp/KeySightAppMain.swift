import AppKit
import SwiftUI
import KeySightCore

@main
@MainActor
struct KeySightLauncher {
    // NSApplication.delegate is weak, so keep a strong reference for the full app lifetime
    private static var appDelegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.appDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var viewModel: KeySightViewModel!
    private var panelController: FloatingPanelController!
    private var hotkeyManager: GlobalHotkeyManager!
    private var searchRequestObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent duplicate instances if user double-clicks the app again
        if let bundleID = Bundle.main.bundleIdentifier {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            if running.count > 1 {
                DistributedNotificationCenter.default().post(
                    name: Notification.Name("com.xinque.keysight.reopen"),
                    object: nil
                )
                NSApp.terminate(nil)
                return
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.xinque.keysight.reopen"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.panelController.showPinnedHUD(focusSearch: false)
            }
        }

        viewModel = KeySightViewModel()
        panelController = FloatingPanelController(viewModel: viewModel)
        hotkeyManager = GlobalHotkeyManager()

        wireCallbacks()
        setupStatusBarItem()

        hotkeyManager.isCommandHoldEnabled = viewModel.isCommandHoldEnabled
        hotkeyManager.commandHoldDelay = viewModel.commandHoldDelay
        hotkeyManager.start()

        // Show the floating HUD right away on launch so user gets immediate feedback
        panelController.showPinnedHUD(focusSearch: false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager?.stop()
        viewModel?.stopMonitoring()
        if let obs = searchRequestObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    private func wireCallbacks() {
        hotkeyManager.onCommandHoldStart = { [weak self] in
            self?.panelController.showPeekOverlay()
        }
        hotkeyManager.onCommandHoldEnd = { [weak self] in
            self?.panelController.hidePeekOverlay()
        }
        hotkeyManager.onHeldModifiersChanged = { [weak self] mods in
            self?.viewModel.liveHeldModifiers = mods
        }
        hotkeyManager.onPromoteOverlayToSearch = { [weak self] in
            self?.panelController.promoteOverlayToSearch()
        }
        hotkeyManager.onOverlayPageStep = { [weak self] delta in
            self?.viewModel.stepOverlayPage(delta: delta)
        }
        hotkeyManager.canPageOverlay = { [weak self] in
            (self?.viewModel.overlayPages.count ?? 0) > 1
        }
        hotkeyManager.onTogglePinnedHUD = { [weak self] in
            self?.panelController.togglePinnedHUD()
        }
        hotkeyManager.onOpenSearchMode = { [weak self] in
            self?.panelController.openSearchMode()
        }

        viewModel.onAccessibilityGranted = { [weak self] in
            self?.hotkeyManager.ensureOverlayEventTapIfTrusted()
        }

        viewModel.onPreferenceChanged = { [weak self] in
            guard let self else { return }
            self.hotkeyManager.isCommandHoldEnabled = self.viewModel.isCommandHoldEnabled
            self.hotkeyManager.commandHoldDelay = self.viewModel.commandHoldDelay
            self.rebuildStatusMenu()
        }

        viewModel.onAppearanceChanged = { [weak self] style in
            self?.panelController.applyAppearanceStyle(style)
        }

        viewModel.onRequestPinFromOverlay = { [weak self] in
            self?.hotkeyManager.resetHoldStateWithoutDismiss()
            self?.panelController.pinFromOverlay()
        }

        viewModel.onRequestDismissSearch = { [weak self] in
            self?.panelController.exitSearchFocus()
        }

        viewModel.onRequestCloseHUD = { [weak self] in
            self?.panelController.hideAll()
        }

        searchRequestObserver = NotificationCenter.default.addObserver(
            forName: .ksRequestActivateSearch,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.panelController.activateSearchFocus()
            }
        }
    }

    // MARK: - Menu Bar Status Item

    private func setupStatusBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "command.square.fill", accessibilityDescription: "KeySight") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "⌘"
            }
            button.toolTip = "KeySight — 智能快捷键悬浮窗"
        }
        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let header = NSMenuItem(title: "KeySight · 智能快捷键提示", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let toggleItem = NSMenuItem(
            title: panelController.isVisible ? "隐藏悬浮窗 (⌥⇧K)" : "显示常驻悬浮窗 (⌥⇧K)",
            action: #selector(menuTogglePinnedHUD),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        let searchItem = NSMenuItem(
            title: "搜索并执行快捷键 (⌥⇧F)",
            action: #selector(menuOpenSearch),
            keyEquivalent: ""
        )
        searchItem.target = self
        menu.addItem(searchItem)

        menu.addItem(.separator())

        let holdToggle = NSMenuItem(
            title: "长按 ⌘ 键瞬间呼出全览",
            action: #selector(menuToggleCommandHold),
            keyEquivalent: ""
        )
        holdToggle.target = self
        holdToggle.state = viewModel.isCommandHoldEnabled ? .on : .off
        menu.addItem(holdToggle)

        let delayMenu = NSMenu()
        let presets: [(String, Double)] = [
            ("快速 (0.30 秒)", 0.30),
            ("适中 (0.45 秒 · 推荐)", 0.45),
            ("稳妥防误触 (0.65 秒)", 0.65)
        ]
        for (label, value) in presets {
            let item = NSMenuItem(title: label, action: #selector(menuSetHoldDelay(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = abs(viewModel.commandHoldDelay - value) < 0.05 ? .on : .off
            delayMenu.addItem(item)
        }
        let delayRoot = NSMenuItem(title: "长按 ⌘ 呼出延迟", action: nil, keyEquivalent: "")
        delayRoot.submenu = delayMenu
        menu.addItem(delayRoot)

        let styleMenu = NSMenu()
        for style in HUDAppearanceStyle.allCases {
            let item = NSMenuItem(
                title: style.menuDescription,
                action: #selector(menuSetAppearanceStyle(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = style.rawValue
            item.state = (viewModel.appearanceStyle == style) ? .on : .off
            styleMenu.addItem(item)
        }
        let styleRoot = NSMenuItem(
            title: "悬浮窗外观材质（\(viewModel.appearanceStyle.displayName)）",
            action: nil,
            keyEquivalent: ""
        )
        styleRoot.submenu = styleMenu
        menu.addItem(styleRoot)

        let enabledOnlyItem = NSMenuItem(
            title: "仅显示当前界面可用快捷键",
            action: #selector(menuToggleOnlyEnabled),
            keyEquivalent: ""
        )
        enabledOnlyItem.target = self
        enabledOnlyItem.state = viewModel.onlyEnabled ? .on : .off
        menu.addItem(enabledOnlyItem)

        let hideBasicItem = NSMenuItem(
            title: "隐藏通用基础键 (⌘C/V/X/Z/A/S/W/Q 等)",
            action: #selector(menuToggleHideBasic),
            keyEquivalent: ""
        )
        hideBasicItem.target = self
        hideBasicItem.state = viewModel.hideBasicShortcuts ? .on : .off
        menu.addItem(hideBasicItem)

        let suppItem = NSMenuItem(
            title: "包含系统/常用软件免触控板推荐",
            action: #selector(menuToggleSupplemental),
            keyEquivalent: ""
        )
        suppItem.target = self
        suppItem.state = viewModel.includeSupplemental ? .on : .off
        menu.addItem(suppItem)

        menu.addItem(.separator())

        let trusted = AccessibilityScanner.isAccessibilityTrusted(prompt: false)
        let permItem = NSMenuItem(
            title: trusted ? "辅助功能权限：已授权 ✓" : "辅助功能权限：未授权（点击前往设置）",
            action: #selector(menuOpenAccessibilitySettings),
            keyEquivalent: ""
        )
        permItem.target = self
        menu.addItem(permItem)

        if !trusted {
            let resetPermItem = NSMenuItem(
                title: "重置旧授权记录并重新授权（已勾选仍无效时点此）",
                action: #selector(menuResetAccessibilityPermission),
                keyEquivalent: ""
            )
            resetPermItem.target = self
            menu.addItem(resetPermItem)
        }

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 KeySight", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func menuTogglePinnedHUD() {
        panelController.togglePinnedHUD()
    }

    @objc private func menuOpenSearch() {
        panelController.openSearchMode()
    }

    @objc private func menuToggleCommandHold() {
        viewModel.isCommandHoldEnabled.toggle()
    }

    @objc private func menuSetHoldDelay(_ sender: NSMenuItem) {
        if let delay = sender.representedObject as? Double {
            viewModel.commandHoldDelay = delay
        }
    }

    @objc private func menuSetAppearanceStyle(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String,
           let style = HUDAppearanceStyle(rawValue: raw) {
            viewModel.appearanceStyle = style
            viewModel.showToast("已切换外观：\(style.displayName)")
        }
    }

    @objc private func menuToggleOnlyEnabled() {
        viewModel.onlyEnabled.toggle()
    }

    @objc private func menuToggleHideBasic() {
        viewModel.hideBasicShortcuts.toggle()
    }

    @objc private func menuToggleSupplemental() {
        viewModel.includeSupplemental.toggle()
    }

    @objc private func menuOpenAccessibilitySettings() {
        viewModel.requestAccessibilityPermission()
    }

    @objc private func menuResetAccessibilityPermission() {
        viewModel.resetAndRequestAccessibilityPermission()
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        viewModel.refreshPermissionStatus()
        rebuildStatusMenu()
    }
}
