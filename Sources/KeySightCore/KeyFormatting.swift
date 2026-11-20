import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum KeyFormatting {
    /// Decodes macOS Accessibility `kAXMenuItemCmdModifiersAttribute` bitmask.
    /// Per Carbon `Menus.h`:
    /// - bit 0 (1): Shift
    /// - bit 1 (2): Option
    /// - bit 2 (4): Control
    /// - bit 3 (8): kMenuNoCommandModifier (when 0, Command is included!)
    public static func decodeAXModifiers(_ rawMask: Int?) -> KeyModifiers {
        let mask = rawMask ?? 0
        var mods: KeyModifiers = []
        if (mask & (1 << 2)) != 0 { mods.insert(.control) }
        if (mask & (1 << 1)) != 0 { mods.insert(.option) }
        if (mask & (1 << 0)) != 0 { mods.insert(.shift) }
        if (mask & (1 << 3)) == 0 { mods.insert(.command) }
        return mods
    }

    /// Builds a `KeyCombo` from raw macOS Accessibility attributes on an `AXMenuItem`.
    public static func buildKeyCombo(
        cmdChar: String?,
        virtualKey: Int?,
        glyph: Int?,
        modifiersRaw: Int?
    ) -> KeyCombo? {
        var keyDisplay: String?
        var resolvedVirtualKey: UInt16? = virtualKey.flatMap { $0 >= 0 && $0 <= 0xFF ? UInt16($0) : nil }

        // 1. Prefer explicit glyph mapping for special keys (arrows, Return, Tab, F-keys, etc.)
        if let g = glyph, let mapped = glyphToDisplay(g) {
            keyDisplay = mapped
        }

        // 2. Fallback to virtual key code if glyph didn't resolve
        if keyDisplay == nil, let vk = virtualKey, let mapped = virtualKeyToDisplay(vk) {
            keyDisplay = mapped
        }

        // 3. Fallback to cmdChar
        if keyDisplay == nil, let rawChar = cmdChar, !rawChar.isEmpty {
            keyDisplay = normalizeCmdChar(rawChar)
        }

        guard let finalKey = keyDisplay, !finalKey.isEmpty else {
            return nil
        }

        let mods = decodeAXModifiers(modifiersRaw)

        // If cmdChar is an uppercase ASCII letter and Shift wasn't explicitly set in modifiers,
        // note that macOS AX typically reports uppercase letters ("N") for ⌘N (without Shift).
        // So we do NOT implicitly add Shift for uppercase ASCII letters — we rely strictly on bit 0!
        // However, if a menu item uses a glyph or special key with modifiersRaw == 8 (NoCommand) and no other mods,
        // that's valid (e.g. Space or F5).

        if resolvedVirtualKey == nil {
            resolvedVirtualKey = keyDisplayToVirtualKey(finalKey)
        }

        // Clean up impossible bare control-character leftovers
        if finalKey.unicodeScalars.allSatisfy({ $0.value < 0x20 }) {
            return nil
        }

        // Handle edge case where glyph was Shift/etc. alone
        if ["⇧", "⌃", "⌥", "⌘"].contains(finalKey) {
            return nil
        }

        // Normalize mods if virtualKey indicates plain key without modifiers
        if mods.isEmpty && finalKey.count == 1 && finalKey.first?.isLetter == true {
            // Bare single letter as a menu shortcut is usually an AX artifact; skip unless modified
            return nil
        }

        return KeyCombo(modifiers: mods, keyDisplay: finalKey, virtualKeyCode: resolvedVirtualKey)
    }

    public static func normalizeCmdChar(_ raw: String) -> String? {
        guard let scalar = raw.unicodeScalars.first else { return nil }
        switch scalar.value {
        case 0x09: return "⇥"
        case 0x0D, 0x0A, 0x03: return "↩"
        case 0x1B: return "⎋"
        case 0x20: return "Space"
        case 0x7F, 0x08: return "⌫"
        case 0xF700, 0x1E: return "↑"
        case 0xF701, 0x1F: return "↓"
        case 0xF702, 0x1C: return "←"
        case 0xF703, 0x1D: return "→"
        case 0xF728: return "⌦"
        case 0xF729: return "↖"
        case 0xF72B: return "↘"
        case 0xF72C: return "⇞"
        case 0xF72D: return "⇟"
        case 0xF704...0xF712:
            let fnNumber = Int(scalar.value - 0xF704) + 1
            return "F\(fnNumber)"
        default:
            let trimmed = raw.trimmingCharacters(in: .newlines)
            guard !trimmed.isEmpty else { return nil }
            return trimmed.uppercased()
        }
    }

    public static func glyphToDisplay(_ glyph: Int) -> String? {
        switch glyph {
        case 2:   return "⇥"
        case 3:   return "⇤"
        case 4:   return "⌤"
        case 9:   return "Space"
        case 10:  return "⌦"
        case 11, 12: return "↩"
        case 23:  return "⌫"
        case 27:  return "⎋"
        case 28:  return "⌧"
        case 98:  return "⇞"
        case 100: return "←"
        case 101: return "→"
        case 102: return "↖"
        case 104: return "↑"
        case 105: return "↘"
        case 106: return "↓"
        case 107: return "⇟"
        case 111...122:
            return "F\(glyph - 110)"
        case 135: return "F13"
        case 136: return "F14"
        case 137: return "F15"
        default:
            return nil
        }
    }

    public static func virtualKeyToDisplay(_ vk: Int) -> String? {
        switch vk {
        case 0x24: return "↩"
        case 0x30: return "⇥"
        case 0x31: return "Space"
        case 0x33: return "⌫"
        case 0x35: return "⎋"
        case 0x4C: return "⌤"
        case 0x73: return "↖"
        case 0x74: return "⇞"
        case 0x75: return "⌦"
        case 0x77: return "↘"
        case 0x79: return "⇟"
        case 0x7B: return "←"
        case 0x7C: return "→"
        case 0x7D: return "↓"
        case 0x7E: return "↑"
        case 0x7A: return "F1"
        case 0x78: return "F2"
        case 0x63: return "F3"
        case 0x76: return "F4"
        case 0x60: return "F5"
        case 0x61: return "F6"
        case 0x62: return "F7"
        case 0x64: return "F8"
        case 0x65: return "F9"
        case 0x6D: return "F10"
        case 0x67: return "F11"
        case 0x6F: return "F12"
        default:
            return nil
        }
    }

    /// Maps normalized keyDisplay strings to US ANSI macOS CGKeyCode for synthetic execution.
    public static func keyDisplayToVirtualKey(_ key: String) -> UInt16? {
        let upper = key.uppercased()
        let map: [String: UInt16] = [
            "A": 0x00, "S": 0x01, "D": 0x02, "F": 0x03, "H": 0x04, "G": 0x05,
            "Z": 0x06, "X": 0x07, "C": 0x08, "V": 0x09, "B": 0x0B, "Q": 0x0C,
            "W": 0x0D, "E": 0x0E, "R": 0x0F, "Y": 0x10, "T": 0x11, "1": 0x12,
            "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
            "+": 0x18, "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D,
            "]": 0x1E, "O": 0x1F, "U": 0x20, "[": 0x21, "I": 0x22, "P": 0x23,
            "↩": 0x24, "L": 0x25, "J": 0x26, "'": 0x27, "K": 0x28, ";": 0x29,
            "\\": 0x2A, ",": 0x2B, "/": 0x2C, "N": 0x2D, "M": 0x2E, ".": 0x2F,
            "⇥": 0x30, "TAB": 0x30, "SPACE": 0x31, "`": 0x32, "⌫": 0x33,
            "⎋": 0x35, "ESC": 0x35, "↖": 0x73, "⇞": 0x74, "⌦": 0x75,
            "↘": 0x77, "⇟": 0x79, "←": 0x7B, "→": 0x7C, "↓": 0x7D, "↑": 0x7E,
            "F1": 0x7A, "F2": 0x78, "F3": 0x63, "F4": 0x76, "F5": 0x60,
            "F6": 0x61, "F7": 0x62, "F8": 0x64, "F9": 0x65, "F10": 0x6D,
            "F11": 0x67, "F12": 0x6F
        ]
        return map[upper]
    }

    #if canImport(CoreGraphics)
    public static func cgEventFlags(from modifiers: KeyModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option)  { flags.insert(.maskAlternate) }
        if modifiers.contains(.shift)   { flags.insert(.maskShift) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        return flags
    }
    #endif
}
