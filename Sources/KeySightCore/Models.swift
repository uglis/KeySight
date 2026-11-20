import Foundation

public enum ShortcutSource: String, Codable, Hashable, Sendable {
    case liveMenu
    case contextTip
    case appSupplemental
    case systemGlobal
}

public enum FocusContextKind: String, Codable, Hashable, Sendable {
    case textInput
    case listOrTable
    case browserWeb
    case general

    public var displayLabel: String {
        switch self {
        case .textInput: return "文本输入区"
        case .listOrTable: return "列表 / 文件视图"
        case .browserWeb: return "网页浏览区"
        case .general: return "标准窗口"
        }
    }

    public var systemSymbol: String {
        switch self {
        case .textInput: return "character.cursor.ibeam"
        case .listOrTable: return "list.bullet.rectangle"
        case .browserWeb: return "globe"
        case .general: return "macwindow"
        }
    }
}

public struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let control = KeyModifiers(rawValue: 1 << 0)
    public static let option  = KeyModifiers(rawValue: 1 << 1)
    public static let shift   = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)

    /// Ordered keycap symbols following macOS HIG: ⌃ ⌥ ⇧ ⌘
    public var symbols: [String] {
        var result: [String] = []
        if contains(.control) { result.append("⌃") }
        if contains(.option)  { result.append("⌥") }
        if contains(.shift)   { result.append("⇧") }
        if contains(.command) { result.append("⌘") }
        return result
    }

    /// Searchable ASCII tokens so users can type "cmd", "opt", "ctrl", "shift"
    public var searchTokens: [String] {
        var result: [String] = []
        if contains(.control) { result.append(contentsOf: ["ctrl", "control", "⌃"]) }
        if contains(.option)  { result.append(contentsOf: ["opt", "option", "alt", "⌥"]) }
        if contains(.shift)   { result.append(contentsOf: ["shift", "⇧"]) }
        if contains(.command) { result.append(contentsOf: ["cmd", "command", "⌘"]) }
        return result
    }
}

public struct KeyCombo: Codable, Hashable, Sendable {
    public let modifiers: KeyModifiers
    public let keyDisplay: String
    public let virtualKeyCode: UInt16?

    public init(modifiers: KeyModifiers, keyDisplay: String, virtualKeyCode: UInt16? = nil) {
        self.modifiers = modifiers
        self.keyDisplay = keyDisplay
        self.virtualKeyCode = virtualKeyCode
    }

    /// Keycaps rendered individually in the UI, e.g. ["⌃", "⇧", "T"]
    public var keycaps: [String] {
        modifiers.symbols + [keyDisplay]
    }

    /// Compact string form, e.g. "⌃⇧T"
    public var displayString: String {
        keycaps.joined()
    }

    /// Stable normalized signature for deduplication (ignores case differences)
    public var normalizedSignature: String {
        "\(modifiers.rawValue)::\(keyDisplay.uppercased())"
    }
}

public struct ShortcutItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let appBundleID: String
    public let title: String
    public let subtitle: String?
    public let category: String
    public let keyCombo: KeyCombo
    public let isEnabled: Bool
    public let source: ShortcutSource
    public let menuPath: [String]
    public let priority: Int

    public init(
        id: String? = nil,
        appBundleID: String,
        title: String,
        subtitle: String? = nil,
        category: String,
        keyCombo: KeyCombo,
        isEnabled: Bool = true,
        source: ShortcutSource,
        menuPath: [String] = [],
        priority: Int = 0
    ) {
        self.id = id ?? "\(appBundleID)::\(category)::\(title)::\(keyCombo.normalizedSignature)"
        self.appBundleID = appBundleID
        self.title = title
        self.subtitle = subtitle
        self.category = category
        self.keyCombo = keyCombo
        self.isEnabled = isEnabled
        self.source = source
        self.menuPath = menuPath
        self.priority = priority
    }
}

public struct AppScanSnapshot: Sendable {
    public let pid: pid_t
    public let bundleID: String
    public let appName: String
    public let windowTitle: String?
    public let focusContext: FocusContextKind
    public let focusedRole: String?
    public let liveMenuShortcuts: [ShortcutItem]
    public let scannedAt: Date

    public init(
        pid: pid_t,
        bundleID: String,
        appName: String,
        windowTitle: String? = nil,
        focusContext: FocusContextKind = .general,
        focusedRole: String? = nil,
        liveMenuShortcuts: [ShortcutItem] = [],
        scannedAt: Date = Date()
    ) {
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.focusContext = focusContext
        self.focusedRole = focusedRole
        self.liveMenuShortcuts = liveMenuShortcuts
        self.scannedAt = scannedAt
    }
}

public struct ShortcutGroup: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let items: [ShortcutItem]

    public init(title: String, items: [ShortcutItem]) {
        self.id = title
        self.title = title
        self.items = items
    }
}

public enum HUDDisplayMode: String, Codable, Sendable {
    /// Hold-⌘ wide glanceable cheat-sheet overlay
    case peekOverlay
    /// Always-on-top compact floating sidebar/card
    case pinnedHUD
}

public enum HUDAppearanceStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Apple macOS 26+ native Liquid Glass Clear (Dock-style pure optical refraction)
    case liquidGlassClear
    /// Apple macOS 26+ native Liquid Glass Regular (adaptive frosted optical glass)
    case liquidGlass
    /// Classic macOS NSVisualEffectView frosted HUD
    case frostedHUD
    /// High-contrast opaque-tinted dark card
    case solidGraphite

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .liquidGlassClear: return "程序坞玻璃"
        case .liquidGlass: return "标准液态玻璃"
        case .frostedHUD: return "经典磨砂"
        case .solidGraphite: return "高对比深色"
        }
    }

    public var menuDescription: String {
        switch self {
        case .liquidGlassClear: return "程序坞同款液态玻璃 (Dock Clear Glass · 推荐)"
        case .liquidGlass: return "标准液态玻璃 (Liquid Glass Regular)"
        case .frostedHUD: return "经典磨砂玻璃 (Frosted HUD)"
        case .solidGraphite: return "高对比深色卡片 (Solid Graphite)"
        }
    }

    public var systemSymbol: String {
        switch self {
        case .liquidGlassClear: return "sparkles.rectangle.stack"
        case .liquidGlass: return "drop.halffull"
        case .frostedHUD: return "square.on.square.dashed"
        case .solidGraphite: return "moon.fill"
        }
    }

    public var isLiquidGlass: Bool {
        self == .liquidGlass || self == .liquidGlassClear
    }

    public var next: HUDAppearanceStyle {
        let all = Self.allCases
        guard let idx = all.firstIndex(of: self) else { return .liquidGlassClear }
        return all[(idx + 1) % all.count]
    }
}
