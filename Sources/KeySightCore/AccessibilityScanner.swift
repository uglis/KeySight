import Foundation
import ApplicationServices
import CoreGraphics

public final class AccessibilityScanner: Sendable {
    public init() {}

    public static func isAccessibilityTrusted(prompt: Bool = false) -> Bool {
        if prompt {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [key: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }

    public func scanApplication(pid: pid_t, bundleID: String, appName: String) -> AppScanSnapshot {
        guard Self.isAccessibilityTrusted(prompt: false) else {
            return AppScanSnapshot(
                pid: pid,
                bundleID: bundleID,
                appName: appName,
                focusContext: .general,
                liveMenuShortcuts: []
            )
        }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.4)

        // 1. Inspect focused window & UI element to classify current context
        let windowTitle = readFocusedWindowTitle(appElement: appElement)
        let (focusContext, focusedRole) = detectFocusContext(appElement: appElement, bundleID: bundleID)

        // 2. Scan live menu bar items and their real-time enabled state
        var liveShortcuts: [ShortcutItem] = []
        if let menuBar = copyAXElement(appElement, attribute: kAXMenuBarAttribute) {
            let topItems = copyAXChildren(menuBar)
            for (index, barItem) in topItems.enumerated() {
                let rawTitle = copyStringAttribute(barItem, attribute: kAXTitleAttribute) ?? ""
                // Skip Apple menu (index 0 is typically the Apple menu)
                if index == 0 && (rawTitle == "Apple" || rawTitle == "" || rawTitle.isEmpty) {
                    continue
                }
                let category = rawTitle.isEmpty ? appName : rawTitle
                // Each AXMenuBarItem contains one AXMenu child
                let subChildren = copyAXChildren(barItem)
                for menu in subChildren {
                    collectMenuShortcuts(
                        from: menu,
                        appBundleID: bundleID,
                        topCategory: category,
                        parentTrail: [category],
                        depth: 0,
                        into: &liveShortcuts
                    )
                }
            }
        }

        return AppScanSnapshot(
            pid: pid,
            bundleID: bundleID,
            appName: appName,
            windowTitle: windowTitle,
            focusContext: focusContext,
            focusedRole: focusedRole,
            liveMenuShortcuts: liveShortcuts,
            scannedAt: Date()
        )
    }

    /// Executes a shortcut on the target app: uses direct AXPress for live menu items,
    /// falling back to synthetic CGEvent keystroke for supplemental/non-menu shortcuts.
    @discardableResult
    public func executeShortcut(_ item: ShortcutItem, targetPID: pid_t) -> Bool {
        if item.source == .liveMenu, !item.menuPath.isEmpty {
            if performMenuPathPress(path: item.menuPath, pid: targetPID) {
                return true
            }
        }

        // Fallback: synthesize key press event
        guard let vk = item.keyCombo.virtualKeyCode ?? KeyFormatting.keyDisplayToVirtualKey(item.keyCombo.keyDisplay) else {
            return false
        }

        let flags = KeyFormatting.cgEventFlags(from: item.keyCombo.modifiers)
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vk, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vk, keyDown: false) else {
            return false
        }

        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - Menu Traversal (Batched AX IPC for minimal CPU & energy)

    private static let menuItemAttributes: CFArray = [
        kAXTitleAttribute as CFString,
        kAXEnabledAttribute as CFString,
        "AXMenuItemCmdChar" as CFString,
        "AXMenuItemCmdVirtualKey" as CFString,
        "AXMenuItemCmdGlyph" as CFString,
        "AXMenuItemCmdModifiers" as CFString
    ] as CFArray

    /// Huge dynamic menus that almost never hold custom keyboard shortcuts; skip recursing deep into them.
    private static let skippedSubmenuTitles: Set<String> = [
        "书签", "Bookmarks", "最近打开", "最近使用", "Open Recent", "Recent",
        "服务", "Services", "语音", "Speech", "替换", "Substitutions",
        "转换", "Transformations", "听写", "Dictation", "自动填充", "AutoFill",
        "写作工具", "Writing Tools", "共享", "Share"
    ]

    private func collectMenuShortcuts(
        from menuElement: AXUIElement,
        appBundleID: String,
        topCategory: String,
        parentTrail: [String],
        depth: Int,
        into results: inout [ShortcutItem]
    ) {
        guard depth <= 2, results.count < 320 else { return }

        let children = copyAXChildren(menuElement)
        let cap = depth == 0 ? 90 : 40

        for child in children.prefix(cap) {
            guard results.count < 320 else { break }

            // Fetch all 6 attributes in ONE single Mach IPC round-trip (6x fewer IPCs than separate calls!)
            var valuesRef: CFArray?
            let err = AXUIElementCopyMultipleAttributeValues(child, Self.menuItemAttributes, [], &valuesRef)
            guard err == .success, let rawValues = valuesRef as? [Any], rawValues.count == 6 else {
                continue
            }

            let title = (rawValues[0] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty {
                continue
            }

            let isEnabled = (rawValues[1] as? Bool) ?? true
            let cmdChar = rawValues[2] as? String
            let virtualKey = (rawValues[3] as? NSNumber)?.intValue
            let glyph = (rawValues[4] as? NSNumber)?.intValue
            let modifiersRaw = (rawValues[5] as? NSNumber)?.intValue

            if let combo = KeyFormatting.buildKeyCombo(
                cmdChar: cmdChar,
                virtualKey: virtualKey,
                glyph: glyph,
                modifiersRaw: modifiersRaw
            ) {
                let fullPath = parentTrail + [title]
                let subtitle: String? = parentTrail.count > 1
                    ? parentTrail.dropFirst().joined(separator: " → ")
                    : nil

                let item = ShortcutItem(
                    appBundleID: appBundleID,
                    title: title,
                    subtitle: subtitle,
                    category: topCategory,
                    keyCombo: combo,
                    isEnabled: isEnabled,
                    source: .liveMenu,
                    menuPath: fullPath,
                    priority: isEnabled ? 60 : 10
                )
                results.append(item)
                // Items with a direct keyboard shortcut don't host submenus; skip child IPC lookup!
                continue
            }

            // Recurse into submenus only when item has no direct shortcut and isn't a huge dynamic menu
            if depth < 2 && !Self.skippedSubmenuTitles.contains(title) {
                let submenus = copyAXChildren(child)
                for submenu in submenus {
                    let role = copyStringAttribute(submenu, attribute: kAXRoleAttribute)
                    if role == (kAXMenuRole as String) {
                        collectMenuShortcuts(
                            from: submenu,
                            appBundleID: appBundleID,
                            topCategory: topCategory,
                            parentTrail: parentTrail + [title],
                            depth: depth + 1,
                            into: &results
                        )
                    }
                }
            }
        }
    }

    // MARK: - Live Menu Execution

    private func performMenuPathPress(path: [String], pid: pid_t) -> Bool {
        guard !path.isEmpty else { return false }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.5)

        guard let menuBar = copyAXElement(appElement, attribute: kAXMenuBarAttribute) else {
            return false
        }

        // Find top-level menu bar item
        let topItems = copyAXChildren(menuBar)
        guard let barItem = topItems.first(where: {
            (copyStringAttribute($0, attribute: kAXTitleAttribute) ?? "") == path[0]
        }) else {
            return false
        }

        var currentContainer: AXUIElement? = copyAXChildren(barItem).first
        let remaining = Array(path.dropFirst())
        guard !remaining.isEmpty else { return false }

        for (idx, stepTitle) in remaining.enumerated() {
            guard let menu = currentContainer else { return false }
            let items = copyAXChildren(menu)
            guard let matched = items.first(where: {
                (copyStringAttribute($0, attribute: kAXTitleAttribute) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines) == stepTitle
            }) else {
                return false
            }

            if idx == remaining.count - 1 {
                let err = AXUIElementPerformAction(matched, kAXPressAction as CFString)
                return err == .success
            } else {
                currentContainer = copyAXChildren(matched).first(where: {
                    copyStringAttribute($0, attribute: kAXRoleAttribute) == (kAXMenuRole as String)
                })
            }
        }
        return false
    }

    // MARK: - Context Detection

    private func readFocusedWindowTitle(appElement: AXUIElement) -> String? {
        guard let window = copyAXElement(appElement, attribute: kAXFocusedWindowAttribute) else {
            return nil
        }
        let title = copyStringAttribute(window, attribute: kAXTitleAttribute)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (title?.isEmpty == false) ? title : nil
    }

    private func detectFocusContext(appElement: AXUIElement, bundleID: String) -> (FocusContextKind, String?) {
        let focused = copyAXElement(appElement, attribute: kAXFocusedUIElementAttribute)
        let role = focused.flatMap { copyStringAttribute($0, attribute: kAXRoleAttribute) }
        let subrole = focused.flatMap { copyStringAttribute($0, attribute: kAXSubroleAttribute) }

        if let r = role {
            let textRoles: Set<String> = [
                "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"
            ]
            if textRoles.contains(r) || subrole == "AXSearchField" {
                return (.textInput, r)
            }

            // Check if a web/custom element supports text editing via settable AXValue or AXSelectedTextRange
            if let el = focused {
                var isValueSettable = DarwinBoolean(false)
                if AXUIElementIsAttributeSettable(el, kAXSelectedTextAttribute as CFString, &isValueSettable) == .success,
                   isValueSettable.boolValue {
                    return (.textInput, r)
                }
            }

            let listRoles: Set<String> = [
                "AXOutline", "AXTable", "AXList", "AXBrowser", "AXRow", "AXCell", "AXIcon"
            ]
            if listRoles.contains(r) {
                return (.listOrTable, r)
            }

            if r == "AXWebArea" || r == "AXLink" {
                return (.browserWeb, r)
            }
        }

        // Heuristic fallback for browsers when focused element is a container
        let lower = bundleID.lowercased()
        let browsers = ["safari", "chrome", "firefox", "thebrowser", "edgemac", "brave", "opera", "vivaldi", "comet"]
        if browsers.contains(where: { lower.contains($0) }) {
            return (.browserWeb, role)
        }

        if lower == "com.apple.finder" {
            return (.listOrTable, role)
        }

        return (.general, role)
    }

    // MARK: - AX Attribute Helpers

    private func copyAXElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success, let unwrapped = value else { return nil }
        guard CFGetTypeID(unwrapped) == AXUIElementGetTypeID() else { return nil }
        return (unwrapped as! AXUIElement)
    }

    private func copyAXChildren(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        guard err == .success, let array = value as? [AXUIElement] else { return [] }
        return array
    }

    private func copyStringAttribute(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success else { return nil }
        return value as? String
    }

    private func copyBoolAttribute(_ element: AXUIElement, attribute: String) -> Bool? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success else { return nil }
        return value as? Bool
    }

    private func copyIntAttribute(_ element: AXUIElement, attribute: String) -> Int? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success else { return nil }
        if let num = value as? NSNumber {
            return num.intValue
        }
        return value as? Int
    }
}
