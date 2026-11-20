import AppKit
import SwiftUI
import KeySightCore

final class KeySightPanel: NSPanel {
    var allowsKeyFocus: Bool = false

    override var canBecomeKey: Bool { allowsKeyFocus }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FloatingPanelController: NSObject, NSWindowDelegate {
    private let viewModel: KeySightViewModel
    private let panel: KeySightPanel
    private let hostingView: NSHostingView<HUDRootView>
    private var localKeyMonitor: Any?
    private var isPinnedOpen: Bool = false
    private var isOverlayOpen: Bool = false
    private var openedViaSearchOnly: Bool = false

    private static let pinnedFrameKey = "ks.pinnedHUDFrame"

    init(viewModel: KeySightViewModel) {
        self.viewModel = viewModel

        let initialRect = NSRect(x: 0, y: 0, width: 380, height: 560)
        self.panel = KeySightPanel(
            contentRect: initialRect,
            styleMask: [.borderless, .nonactivatingPanel, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        let rootView = HUDRootView(viewModel: viewModel)
        let hosting = NSHostingView(rootView: rootView)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        self.hostingView = hosting

        super.init()

        panel.delegate = self
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 310, height: 340)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.level = .floating

        applyAppearanceStyle(viewModel.appearanceStyle)
        installKeyboardNavigationMonitor()
    }

    func applyAppearanceStyle(_ style: HUDAppearanceStyle) {
        if #available(macOS 26.0, *), style.isLiquidGlass {
            let glassView: NSGlassEffectView
            if let existing = panel.contentView as? NSGlassEffectView {
                glassView = existing
            } else {
                glassView = NSGlassEffectView(frame: panel.contentLayoutRect)
                glassView.autoresizingMask = [.width, .height]
                hostingView.removeFromSuperview()
                hostingView.frame = glassView.bounds
                hostingView.autoresizingMask = [.width, .height]
                glassView.contentView = hostingView
                panel.contentView = glassView
            }

            glassView.cornerRadius = 22
            switch style {
            case .liquidGlass:
                glassView.style = .regular
                glassView.tintColor = nil
            case .liquidGlassClear:
                glassView.style = .clear
                // Subtle adaptive veil keeps keycap typography razor-sharp over bright wallpapers
                glassView.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.08)
            default:
                break
            }

            if #available(macOS 27.0, *) {
                glassView.effectIsInteractive = true
            }
            panel.invalidateShadow()
        } else {
            if panel.contentView !== hostingView {
                if #available(macOS 26.0, *), let existingGlass = panel.contentView as? NSGlassEffectView {
                    existingGlass.contentView = nil
                }
                hostingView.removeFromSuperview()
                hostingView.frame = panel.contentLayoutRect
                hostingView.autoresizingMask = [.width, .height]
                panel.contentView = hostingView
            }
            panel.invalidateShadow()
        }
    }

    deinit {
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Mode Transitions

    /// Hold-⌘ peek overlay: wide glanceable HUD, strictly non-activating.
    func showPeekOverlay() {
        // If user is already in Pinned HUD mode, just refresh and briefly bring forward without disrupting layout
        if isPinnedOpen {
            viewModel.scanCurrentTargetApp(silent: true)
            panel.orderFrontRegardless()
            return
        }

        isOverlayOpen = true
        openedViaSearchOnly = false
        panel.allowsKeyFocus = false
        panel.level = .statusBar
        viewModel.displayMode = .peekOverlay
        viewModel.isSearchActive = false
        viewModel.searchQuery = ""
        viewModel.isHUDVisible = true
        viewModel.scanCurrentTargetApp(silent: false)

        let screen = activeScreen()
        let visible = screen.visibleFrame
        let width = min(960, visible.width - 80)
        let height = min(600, visible.height - 100)
        let origin = NSPoint(
            x: visible.midX - width / 2,
            y: visible.midY - height / 2 + 12
        )
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)

        panel.alphaValue = 0.0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.13
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
        }
    }

    func hidePeekOverlay() {
        guard isOverlayOpen && !isPinnedOpen else { return }
        isOverlayOpen = false
        viewModel.isHUDVisible = false

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.10
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isOverlayOpen, !self.isPinnedOpen else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1.0
            }
        })
    }

    /// Shows or pins the always-on-top compact floating HUD.
    func showPinnedHUD(focusSearch: Bool = false) {
        isOverlayOpen = false
        isPinnedOpen = true
        openedViaSearchOnly = false
        panel.level = .floating
        viewModel.displayMode = .pinnedHUD
        viewModel.isHUDVisible = true
        viewModel.scanCurrentTargetApp(silent: false)

        let targetFrame = savedPinnedFrame() ?? defaultPinnedFrame()
        panel.setFrame(targetFrame, display: true)

        if focusSearch {
            activateSearchFocus()
        } else {
            panel.allowsKeyFocus = false
            viewModel.isSearchActive = false
            panel.alphaValue = 1.0
            panel.orderFrontRegardless()
        }
    }

    func togglePinnedHUD() {
        if isPinnedOpen {
            hideAll()
        } else {
            showPinnedHUD(focusSearch: false)
        }
    }

    /// Converts an active Hold-⌘ overlay into a Pinned HUD in one click.
    func pinFromOverlay() {
        showPinnedHUD(focusSearch: false)
    }

    /// Opens directly into Search & Execute mode (⌥⇧F).
    func openSearchMode() {
        if !isPinnedOpen {
            openedViaSearchOnly = true
            isOverlayOpen = false
            panel.level = .floating
            viewModel.displayMode = .pinnedHUD
            viewModel.isHUDVisible = true
            viewModel.scanCurrentTargetApp(silent: false)

            // Center-upper Spotlight-like search card if not already pinned
            let screen = activeScreen()
            let visible = screen.visibleFrame
            let width: CGFloat = 520
            let height: CGFloat = 480
            let origin = NSPoint(
                x: visible.midX - width / 2,
                y: visible.maxY - height - 110
            )
            panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        }

        activateSearchFocus()
    }

    func activateSearchFocus() {
        panel.allowsKeyFocus = true
        viewModel.isSearchActive = true
        panel.alphaValue = 1.0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        viewModel.onRequestFocusSearch?()
    }

    func exitSearchFocus() {
        viewModel.isSearchActive = false
        viewModel.searchQuery = ""
        panel.allowsKeyFocus = false

        if openedViaSearchOnly && !isPinnedOpen {
            openedViaSearchOnly = false
            hideAll()
        } else if isPinnedOpen {
            // Keep pinned HUD visible, just give focus back cleanly
            panel.orderFrontRegardless()
            NSApp.hide(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                guard let self, self.isPinnedOpen else { return }
                self.panel.orderFrontRegardless()
            }
        }
    }

    func hideAll() {
        isPinnedOpen = false
        isOverlayOpen = false
        openedViaSearchOnly = false
        panel.allowsKeyFocus = false
        viewModel.isSearchActive = false
        viewModel.searchQuery = ""
        viewModel.isHUDVisible = false
        panel.orderOut(nil)
    }

    var isVisible: Bool {
        isPinnedOpen || isOverlayOpen || openedViaSearchOnly
    }

    // MARK: - Window Frame Persistence

    func windowDidMove(_ notification: Notification) {
        persistPinnedFrameIfApplicable()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        persistPinnedFrameIfApplicable()
    }

    private func persistPinnedFrameIfApplicable() {
        guard isPinnedOpen, !openedViaSearchOnly, viewModel.displayMode == .pinnedHUD else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.pinnedFrameKey)
    }

    private func savedPinnedFrame() -> NSRect? {
        guard let str = UserDefaults.standard.string(forKey: Self.pinnedFrameKey) else { return nil }
        let rect = NSRectFromString(str)
        guard rect.width >= 300, rect.height >= 300 else { return nil }
        // Ensure saved frame is visible on at least one connected screen
        let onSomeScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(rect) }
        return onSomeScreen ? rect : nil
    }

    private func defaultPinnedFrame() -> NSRect {
        let visible = activeScreen().visibleFrame
        let width: CGFloat = 376
        let height: CGFloat = min(580, visible.height - 80)
        return NSRect(
            x: visible.maxX - width - 18,
            y: visible.maxY - height - 22,
            width: width,
            height: height
        )
    }

    private func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    // MARK: - Keyboard Navigation in Search Mode

    private func installKeyboardNavigationMonitor() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }

            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])

            switch event.keyCode {
            case 53: // Escape
                if !self.viewModel.searchQuery.isEmpty {
                    self.viewModel.searchQuery = ""
                } else {
                    self.exitSearchFocus()
                }
                return nil

            case 125: // Down Arrow
                self.viewModel.moveSelection(delta: 1)
                return nil

            case 126: // Up Arrow
                self.viewModel.moveSelection(delta: -1)
                return nil

            case 36, 76: // Return / Enter
                self.viewModel.executeSelected()
                return nil

            default:
                // ⌃N / ⌃P Emacs-style list navigation inside KeySight itself!
                if mods == .control && event.charactersIgnoringModifiers?.lowercased() == "n" {
                    self.viewModel.moveSelection(delta: 1)
                    return nil
                }
                if mods == .control && event.charactersIgnoringModifiers?.lowercased() == "p" {
                    self.viewModel.moveSelection(delta: -1)
                    return nil
                }
                // ⌘P -> Pin selected item
                if mods == .command && event.charactersIgnoringModifiers?.lowercased() == "p" {
                    self.viewModel.togglePinSelected()
                    return nil
                }
                // ⌘M -> Mark selected item as Mastered
                if mods == .command && event.charactersIgnoringModifiers?.lowercased() == "m" {
                    self.viewModel.toggleMasteredSelected()
                    return nil
                }
                return event
            }
        }
    }
}
