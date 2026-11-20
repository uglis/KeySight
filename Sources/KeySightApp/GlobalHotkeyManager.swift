import AppKit
import Carbon

@MainActor
final class GlobalHotkeyManager {
    var onCommandHoldStart: (() -> Void)?
    var onCommandHoldEnd: (() -> Void)?
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
    private var isHoldActive: Bool = false

    private var hotKeyHandlerRef: EventHandlerRef?
    private var togglePinHotKeyRef: EventHotKeyRef?
    private var searchHotKeyRef: EventHotKeyRef?

    private static let hotKeySignature: OSType = 0x4B534754 // 'KSGT'
    private static let togglePinID: UInt32 = 1
    private static let searchModeID: UInt32 = 2

    func start() {
        installEventMonitors()
        registerCarbonHotKeys()
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

        if let ref = togglePinHotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = searchHotKeyRef { UnregisterEventHotKey(ref) }
        if let handler = hotKeyHandlerRef { RemoveEventHandler(handler) }
        togglePinHotKeyRef = nil
        searchHotKeyRef = nil
        hotKeyHandlerRef = nil
    }

    // MARK: - Hold Command Detection

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
        globalInterruptMonitor = NSEvent.addGlobalMonitorForEvents(matching: interruptMask) { [weak self] _ in
            Task { @MainActor in
                self?.handleInterruptEvent()
            }
        }
        localInterruptMonitor = NSEvent.addLocalMonitorForEvents(matching: interruptMask) { [weak self] event in
            Task { @MainActor in
                // Don't cancel if the user clicked inside KeySight's own overlay (e.g. clicking "钉住" button!)
                if event.type == .leftMouseDown || event.type == .rightMouseDown {
                    if event.window != nil {
                        return
                    }
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
            // Only Command is currently held -> start hold timer if not already running/active
            guard holdWorkItem == nil && !isHoldActive else { return }

            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                // Double-check live hardware modifier state right before showing
                let liveFlags = NSEvent.modifierFlags.intersection([.command, .option, .control, .shift])
                guard liveFlags == .command else {
                    self.holdWorkItem = nil
                    return
                }
                self.isHoldActive = true
                self.holdWorkItem = nil
                self.onCommandHoldStart?()
            }
            holdWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + commandHoldDelay, execute: work)
        } else if !active.contains(.command) {
            // Command released
            cancelPendingHold(notifyEnd: isHoldActive)
        } else {
            // Another modifier was added alongside Command (e.g. user is pressing ⌘⇧...)
            if !isHoldActive {
                // User is executing a multi-modifier shortcut quickly; cancel timer so overlay doesn't pop up
                cancelPendingHold(notifyEnd: false)
            }
        }
    }

    private func handleInterruptEvent() {
        // Any keypress or external click cancels a pending hold, or dismisses an active peek overlay
        cancelPendingHold(notifyEnd: isHoldActive)
    }

    func resetHoldStateWithoutDismiss() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        isHoldActive = false
    }

    private func cancelPendingHold(notifyEnd: Bool) {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        let wasActive = isHoldActive
        isHoldActive = false
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
