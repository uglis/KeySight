import AppKit
import Carbon
import KeySightCore

@MainActor
final class GlobalHotkeyManager {
    var onCommandHoldStart: (() -> Void)?
    var onCommandHoldEnd: (() -> Void)?
    var onHeldModifiersChanged: ((KeyModifiers) -> Void)?
    var onPromoteOverlayToSearch: (() -> Void)?
    var onOverlayPageStep: ((Int) -> Void)?
    var canPageOverlay: (() -> Bool)?

    var onTogglePinnedHUD: (() -> Void)?
    var onOpenSearchMode: (() -> Void)?

    var isCommandHoldEnabled: Bool = true {
        didSet {
            if !isCommandHoldEnabled {
                cancelPendingHold(notifyEnd: isHoldActive)
            }
        }
    }

    var commandHoldDelay: TimeInterval = 0.45

    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalInterruptMonitor: Any?
    private var localInterruptMonitor: Any?

    private var holdWorkItem: DispatchWorkItem?
    fileprivate var isHoldActive: Bool = false

    // Active-only CGEventTap to cleanly intercept Space / '/' / ← / → while Hold-⌘ Overlay is open
    fileprivate var overlayEventTap: CFMachPort?
    private var overlayTapSource: CFRunLoopSource?

    private var hotKeyHandlerRef: EventHandlerRef?
    private var togglePinHotKeyRef: EventHotKeyRef?
    private var searchHotKeyRef: EventHotKeyRef?

    private static let hotKeySignature: OSType = 0x4B534754 // 'KSGT'
    private static let togglePinID: UInt32 = 1
    private static let searchModeID: UInt32 = 2

    func start() {
        installEventMonitors()
        registerCarbonHotKeys()
        ensureOverlayEventTapIfTrusted()
    }

    func stop() {
        cancelPendingHold(notifyEnd: false)
        if let m = globalFlagsMonitor { NSEvent.removeMonitor(m) }
        if let m = localFlagsMonitor { NSEvent.removeMonitor(m) }
        if let m = globalInterruptMonitor { NSEvent.removeMonitor(m) }
        if let m = localInterruptMonitor { NSEvent.removeMonitor(m) }
        globalFlagsMonitor = nil
        localFlagsMonitor = nil
        globalInterruptMonitor = nil
        localInterruptMonitor = nil

        if let tap = overlayEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let src = overlayTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        overlayEventTap = nil
        overlayTapSource = nil

        if let ref = togglePinHotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = searchHotKeyRef { UnregisterEventHotKey(ref) }
        if let handler = hotKeyHandlerRef { RemoveEventHandler(handler) }
        togglePinHotKeyRef = nil
        searchHotKeyRef = nil
        hotKeyHandlerRef = nil
    }

    /// Call once Accessibility permission is granted so the active-only event tap becomes available immediately.
    func ensureOverlayEventTapIfTrusted() {
        guard overlayEventTap == nil, AccessibilityScanner.isAccessibilityTrusted(prompt: false) else { return }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
                return MainActor.assumeIsolated {
                    manager.handleOverlayTapEvent(type: type, event: event)
                }
            },
            userInfo: userInfo
        ) else {
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: false)

        self.overlayEventTap = tap
        self.overlayTapSource = source
    }

    private func setOverlayTapEnabled(_ enabled: Bool) {
        if enabled {
            ensureOverlayEventTapIfTrusted()
        }
        if let tap = overlayEventTap {
            CGEvent.tapEnable(tap: tap, enable: enabled)
        }
    }

    private func handleOverlayTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = overlayEventTap {
                CGEvent.tapEnable(tap: tap, enable: isHoldActive)
            }
            return Unmanaged.passUnretained(event)
        }

        guard isHoldActive, type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let onlyCommand = flags.contains(.maskCommand)
            && !flags.contains(.maskShift)
            && !flags.contains(.maskAlternate)
            && !flags.contains(.maskControl)

        // While Hold-⌘ Overlay is open:
        // 1) Space (0x31) or '/' (0x2C) with only ⌘ -> Lock HUD & jump straight into Search Mode!
        if onlyCommand && (keyCode == 0x31 || keyCode == 0x2C) {
            resetHoldStateWithoutDismiss()
            onPromoteOverlayToSearch?()
            return nil // Consume so Spotlight / '/' does not trigger!
        }

        // 2) ← / → (or ↑ / ↓) with only ⌘ when multiple overlay pages exist -> Keyboard paging!
        if onlyCommand && (canPageOverlay?() == true) {
            switch keyCode {
            case 0x7B, 0x7E: // Left or Up -> Previous page
                onOverlayPageStep?(-1)
                return nil
            case 0x7C, 0x7D: // Right or Down -> Next page
                onOverlayPageStep?(1)
                return nil
            default:
                break
            }
        }

        // Any other key (e.g. ⌘T, ⌘⇧N, ⌘W): pass through to the active app & auto-dismiss overlay!
        cancelPendingHold(notifyEnd: true)
        return Unmanaged.passUnretained(event)
    }

    // MARK: - Hold Command Detection & Live Modifier Chord Filtering

    private func installEventMonitors() {
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlagsChanged(event.modifierFlags)
            }
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlagsChanged(event.modifierFlags)
            }
            return event
        }

        let interruptMask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalInterruptMonitor = NSEvent.addGlobalMonitorForEvents(matching: interruptMask) { [weak self] event in
            Task { @MainActor in
                // If our active-only event tap is running, keyDown is handled cleanly there;
                // mouse clicks still dismiss immediately.
                if event.type == .keyDown && self?.overlayEventTap != nil && self?.isHoldActive == true {
                    return
                }
                self?.handleInterruptEvent()
            }
        }
        localInterruptMonitor = NSEvent.addLocalMonitorForEvents(matching: interruptMask) { [weak self] event in
            Task { @MainActor in
                if event.type == .leftMouseDown || event.type == .rightMouseDown {
                    if event.window != nil {
                        return
                    }
                }
                if event.type == .keyDown && self?.overlayEventTap != nil && self?.isHoldActive == true {
                    return
                }
                self?.handleInterruptEvent()
            }
            return event
        }
    }

    private func handleFlagsChanged(_ rawFlags: NSEvent.ModifierFlags) {
        guard isCommandHoldEnabled else { return }

        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let active = rawFlags.intersection(relevant)

        if active == .command {
            if isHoldActive {
                // User released ⇧/⌥/⌃ while still holding ⌘ -> reset live chord filter back to all
                onHeldModifiersChanged?([.command])
                return
            }

            guard holdWorkItem == nil else { return }

            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let liveFlags = NSEvent.modifierFlags.intersection([.command, .option, .control, .shift])
                guard liveFlags == .command else {
                    self.holdWorkItem = nil
                    return
                }
                self.isHoldActive = true
                self.holdWorkItem = nil
                self.setOverlayTapEnabled(true)
                self.onHeldModifiersChanged?([.command])
                self.onCommandHoldStart?()
            }
            holdWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + commandHoldDelay, execute: work)
        } else if !active.contains(.command) {
            // Command released
            cancelPendingHold(notifyEnd: isHoldActive)
        } else {
            // Another modifier was added alongside Command (e.g. ⌘⇧ / ⌘⌥ / ⌘⌃)
            if isHoldActive {
                // Live Which-Key modifier filtering!
                onHeldModifiersChanged?(Self.convertModifiers(active))
            } else {
                // User is executing a quick multi-modifier shortcut before the hold delay elapsed -> cancel
                cancelPendingHold(notifyEnd: false)
            }
        }
    }

    private static func convertModifiers(_ flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var mods: KeyModifiers = []
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.option)  { mods.insert(.option) }
        if flags.contains(.shift)   { mods.insert(.shift) }
        if flags.contains(.command) { mods.insert(.command) }
        return mods
    }

    private func handleInterruptEvent() {
        cancelPendingHold(notifyEnd: isHoldActive)
    }

    func resetHoldStateWithoutDismiss() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        isHoldActive = false
        setOverlayTapEnabled(false)
        onHeldModifiersChanged?([])
    }

    private func cancelPendingHold(notifyEnd: Bool) {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        let wasActive = isHoldActive
        isHoldActive = false
        setOverlayTapEnabled(false)
        onHeldModifiersChanged?([])
        if notifyEnd && wasActive {
            onCommandHoldEnd?()
        }
    }

    // MARK: - Carbon Global Hotkeys (⌥⇧K & ⌥⇧F)

    private func registerCarbonHotKeys() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                let err = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard err == noErr else { return err }
                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                let id = hotKeyID.id
                Task { @MainActor in
                    manager.handleHotKey(id: id)
                }
                return noErr
            },
            1,
            &eventSpec,
            userData,
            &hotKeyHandlerRef
        )

        guard status == noErr else { return }

        let modifiers = UInt32(optionKey | shiftKey)

        // ⌥⇧K (kVK_ANSI_K = 0x28) -> Toggle Pinned Floating HUD
        let toggleID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.togglePinID)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_K),
            modifiers,
            toggleID,
            GetApplicationEventTarget(),
            0,
            &togglePinHotKeyRef
        )

        // ⌥⇧F (kVK_ANSI_F = 0x03) -> Open Search & Execute Mode
        let searchID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.searchModeID)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_F),
            modifiers,
            searchID,
            GetApplicationEventTarget(),
            0,
            &searchHotKeyRef
        )
    }

    private func handleHotKey(id: UInt32) {
        switch id {
        case Self.togglePinID:
            onTogglePinnedHUD?()
        case Self.searchModeID:
            onOpenSearchMode?()
        default:
            break
        }
    }
}
