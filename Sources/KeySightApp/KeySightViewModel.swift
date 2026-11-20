import AppKit
import Combine
import KeySightCore

@MainActor
final class KeySightViewModel: ObservableObject {
    // MARK: - Published UI State
    @Published var isAccessibilityGranted: Bool = false
    @Published var displayMode: HUDDisplayMode = .pinnedHUD
    @Published var isHUDVisible: Bool = false
    @Published var isSearchActive: Bool = false

    @Published var targetAppName: String = "桌面"
    @Published var targetBundleID: String = ""
    @Published var targetAppIcon: NSImage?
    @Published var windowTitle: String?
    @Published var focusContext: FocusContextKind = .general
    @Published var isScanning: Bool = false

    @Published var searchQuery: String = "" {
        didSet {
            selectedIndex = 0
            recomputeViewResult()
        }
    }
    @Published var selectedCategory: String? = nil {
        didSet {
            selectedIndex = 0
            recomputeViewResult()
        }
    }
    @Published var selectedIndex: Int = 0
    @Published var showMasteredDrawer: Bool = false
    @Published var toastMessage: String?

    // Hold-⌘ zero-trackpad state: live Which-Key modifier chord filter + fixed-height pagination
    @Published var liveHeldModifiers: KeyModifiers = [] {
        didSet {
            if liveHeldModifiers != oldValue {
                overlayPageIndex = 0
                recomputeViewResult()
            }
        }
    }
    @Published var overlayPages: [OverlayPage] = []
    @Published var overlayPageIndex: Int = 0

    @Published var viewResult: ShortcutViewResult = ShortcutViewResult(
        groups: [],
        flatVisibleItems: [],
        masteredItems: [],
        availableCategories: [],
        totalAvailableCount: 0,
        totalMasteredCount: 0
    )

    // MARK: - User Preferences
    @Published var onlyEnabled: Bool {
        didSet {
            UserDefaults.standard.set(onlyEnabled, forKey: Keys.onlyEnabled)
            recomputeViewResult()
        }
    }
    @Published var includeSupplemental: Bool {
        didSet {
            UserDefaults.standard.set(includeSupplemental, forKey: Keys.includeSupplemental)
            recomputeViewResult()
        }
    }
    @Published var hideMastered: Bool {
        didSet {
            UserDefaults.standard.set(hideMastered, forKey: Keys.hideMastered)
            recomputeViewResult()
        }
    }
    @Published var hideBasicShortcuts: Bool {
        didSet {
            UserDefaults.standard.set(hideBasicShortcuts, forKey: Keys.hideBasicShortcuts)
            overlayPageIndex = 0
            recomputeViewResult()
            onPreferenceChanged?()
        }
    }
    @Published var isCommandHoldEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isCommandHoldEnabled, forKey: Keys.commandHoldEnabled)
            onPreferenceChanged?()
        }
    }
    @Published var commandHoldDelay: Double {
        didSet {
            UserDefaults.standard.set(commandHoldDelay, forKey: Keys.commandHoldDelay)
            onPreferenceChanged?()
        }
    }
    @Published var appearanceStyle: HUDAppearanceStyle {
        didSet {
            UserDefaults.standard.set(appearanceStyle.rawValue, forKey: Keys.appearanceStyle)
            onAppearanceChanged?(effectiveAppearanceStyle)
            onPreferenceChanged?()
        }
    }
    /// Eco mode: keeps Hold-⌘ Peek Overlay in full Apple Liquid Glass,
    /// while using ultra-low-GPU rendering for always-on Pinned HUD to keep MacBook Air cool.
    @Published var ecoPinnedMode: Bool {
        didSet {
            UserDefaults.standard.set(ecoPinnedMode, forKey: Keys.ecoPinnedMode)
            onAppearanceChanged?(effectiveAppearanceStyle)
            onPreferenceChanged?()
        }
    }

    var effectiveAppearanceStyle: HUDAppearanceStyle {
        if displayMode == .pinnedHUD && ecoPinnedMode && appearanceStyle.isLiquidGlass {
            return .frostedHUD
        }
        return appearanceStyle
    }

    var onPreferenceChanged: (() -> Void)?
    var onAppearanceChanged: ((HUDAppearanceStyle) -> Void)?
    var onAccessibilityGranted: (() -> Void)?
    var onRequestPinFromOverlay: (() -> Void)?
    var onRequestDismissSearch: (() -> Void)?
    var onRequestCloseHUD: (() -> Void)?
    var onRequestFocusSearch: (() -> Void)?

    // MARK: - Internal Services
    private let scanner = AccessibilityScanner()
    private let progressStore = ShortcutProgressStore()
    private let scanQueue = DispatchQueue(label: "com.xinque.keysight.axscanner", qos: .userInitiated)

    private var targetApp: NSRunningApplication?
    private var currentSnapshot: AppScanSnapshot?
    private var snapshotCache: [pid_t: AppScanSnapshot] = [:]
    private let cacheTTL: TimeInterval = 20.0
    private var scanGeneration: Int = 0
    private var workspaceObserver: NSObjectProtocol?
    private var permissionTimer: Timer?
    private var toastWorkItem: DispatchWorkItem?

    private enum Keys {
        static let onlyEnabled = "ks.onlyEnabled"
        static let includeSupplemental = "ks.includeSupplemental"
        static let hideMastered = "ks.hideMastered"
        static let hideBasicShortcuts = "ks.hideBasicShortcuts"
        static let commandHoldEnabled = "ks.commandHoldEnabled"
        static let commandHoldDelay = "ks.commandHoldDelay"
        static let appearanceStyle = "ks.appearanceStyle"
        static let ecoPinnedMode = "ks.ecoPinnedMode"
    }

    init() {
        let ud = UserDefaults.standard
        self.onlyEnabled = ud.object(forKey: Keys.onlyEnabled) as? Bool ?? true
        self.includeSupplemental = ud.object(forKey: Keys.includeSupplemental) as? Bool ?? true
        self.hideMastered = ud.object(forKey: Keys.hideMastered) as? Bool ?? true
        self.hideBasicShortcuts = ud.object(forKey: Keys.hideBasicShortcuts) as? Bool ?? true
        self.isCommandHoldEnabled = ud.object(forKey: Keys.commandHoldEnabled) as? Bool ?? true
        self.ecoPinnedMode = ud.object(forKey: Keys.ecoPinnedMode) as? Bool ?? true
        let savedDelay = ud.double(forKey: Keys.commandHoldDelay)
        self.commandHoldDelay = savedDelay > 0.1 ? savedDelay : 0.45
        if let savedStyleRaw = ud.string(forKey: Keys.appearanceStyle),
           let savedStyle = HUDAppearanceStyle(rawValue: savedStyleRaw) {
            self.appearanceStyle = savedStyle
        } else {
            self.appearanceStyle = .liquidGlassClear
        }

        self.isAccessibilityGranted = AccessibilityScanner.isAccessibilityTrusted(prompt: false)
        startMonitoring()
    }

    func startMonitoring() {
        captureFrontmostAppIfExternal()

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            Task { @MainActor in
                self?.handleAppActivated(app)
            }
        }

        // Zero background polling timer! Scans are strictly event-driven (on app switch while HUD is visible,
        // or on-demand when Hold-⌘ / Search / Refresh is triggered).
        if !isAccessibilityGranted {
            startPermissionPolling()
        }
    }

    func stopMonitoring() {
        if let obs = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        permissionTimer?.invalidate()
    }

    private func startPermissionPolling() {
        permissionTimer?.invalidate()
        var ticks = 0
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else {
                    timer.invalidate()
                    return
                }
                ticks += 1
                // Stop background polling after 60s if user hasn't granted yet; re-checks on HUD/menu open
                if ticks > 30 && !self.isHUDVisible {
                    timer.invalidate()
                    self.permissionTimer = nil
                    return
                }
                let granted = AccessibilityScanner.isAccessibilityTrusted(prompt: false)
                if granted {
                    self.isAccessibilityGranted = true
                    timer.invalidate()
                    self.permissionTimer = nil
                    self.onAccessibilityGranted?()
                    self.captureFrontmostAppIfExternal()
                    self.scanCurrentTargetApp(silent: false, forceRefresh: true)
                    self.showToast("辅助功能已授权，已开始实时抓取当前界面快捷键")
                }
            }
        }
    }

    func requestAccessibilityPermission() {
        _ = AccessibilityScanner.isAccessibilityTrusted(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        startPermissionPolling()
    }

    /// Clears a stale macOS TCC Accessibility entry (which happens after rebuilding an ad-hoc signed app
    /// when System Settings still displays the old signature's checkbox as enabled) and re-opens Settings.
    func resetAndRequestAccessibilityPermission() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.xinque.KeySight"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "Accessibility", bundleID]
        try? task.run()
        task.waitUntilExit()

        showToast("已清理旧授权记录，请在系统设置中重新勾选 KeySight")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.requestAccessibilityPermission()
        }
    }

    func relaunchApp() {
        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
    }

    func refreshPermissionStatus() {
        isAccessibilityGranted = AccessibilityScanner.isAccessibilityTrusted(prompt: false)
        if isAccessibilityGranted {
            permissionTimer?.invalidate()
            permissionTimer = nil
            scanCurrentTargetApp(silent: false)
        } else {
            startPermissionPolling()
        }
    }

    // MARK: - App Tracking & Live Scanning

    private func captureFrontmostAppIfExternal() {
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            handleAppActivated(front)
        }
    }

    private func handleAppActivated(_ app: NSRunningApplication) {
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let appChanged = targetApp?.processIdentifier != app.processIdentifier
        targetApp = app
        targetAppName = app.localizedName ?? "当前应用"
        targetBundleID = app.bundleIdentifier ?? ""
        targetAppIcon = app.icon

        if appChanged {
            selectedCategory = nil
            selectedIndex = 0
        }

        // Ultra-low energy: when HUD is hidden, do NOT perform AX scans on background app switches!
        guard isHUDVisible else { return }
        scanCurrentTargetApp(silent: !appChanged, forceRefresh: false)
    }

    func scanCurrentTargetApp(silent: Bool = false, forceRefresh: Bool = false) {
        if targetApp == nil {
            captureFrontmostAppIfExternal()
        }
        guard let app = targetApp else { return }

        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier ?? ""
        let appName = app.localizedName ?? "当前应用"

        // Serve fresh per-app cache instantaneously (0ms, 0 AX IPCs!) unless forceRefresh requested
        if !forceRefresh,
           let cached = snapshotCache[pid],
           Date().timeIntervalSince(cached.scannedAt) < cacheTTL {
            self.isScanning = false
            self.currentSnapshot = cached
            self.windowTitle = cached.windowTitle
            self.focusContext = cached.focusContext
            self.recomputeViewResult()
            return
        }

        scanGeneration += 1
        let generation = scanGeneration
        if !silent {
            isScanning = true
        }

        let scannerRef = self.scanner
        scanQueue.async { [weak self] in
            let snapshot = scannerRef.scanApplication(pid: pid, bundleID: bundleID, appName: appName)
            Task { @MainActor in
                guard let self, self.scanGeneration == generation else { return }
                self.isScanning = false
                self.snapshotCache[pid] = snapshot
                // Keep cache bounded to 16 recent apps
                if self.snapshotCache.count > 16,
                   let oldestKey = self.snapshotCache.min(by: { $0.value.scannedAt < $1.value.scannedAt })?.key {
                    self.snapshotCache.removeValue(forKey: oldestKey)
                }
                self.currentSnapshot = snapshot
                self.windowTitle = snapshot.windowTitle
                self.focusContext = snapshot.focusContext
                self.recomputeViewResult()
            }
        }
    }

    /// Only engages live modifier filtering in Peek Overlay when user adds ⇧ / ⌥ / ⌃ on top of ⌘.
    var activeChordFilter: KeyModifiers? {
        guard displayMode == .peekOverlay else { return nil }
        let extra = liveHeldModifiers.subtracting(.command)
        return extra.isEmpty ? nil : liveHeldModifiers
    }

    var currentOverlayPage: OverlayPage? {
        guard !overlayPages.isEmpty else { return nil }
        let idx = max(0, min(overlayPageIndex, overlayPages.count - 1))
        return overlayPages[idx]
    }

    func stepOverlayPage(delta: Int) {
        let count = overlayPages.count
        guard count > 1 else { return }
        overlayPageIndex = (overlayPageIndex + delta + count) % count
    }

    func recomputeViewResult() {
        let snapshot = currentSnapshot ?? AppScanSnapshot(
            pid: targetApp?.processIdentifier ?? 0,
            bundleID: targetBundleID,
            appName: targetAppName,
            focusContext: focusContext,
            liveMenuShortcuts: []
        )

        let options = ShortcutFilterOptions(
            query: searchQuery,
            onlyEnabled: onlyEnabled,
            includeSupplemental: includeSupplemental,
            hideMastered: hideMastered,
            hideBasicShortcuts: hideBasicShortcuts,
            requiredModifiers: activeChordFilter,
            selectedCategory: selectedCategory
        )

        let result = ShortcutSearchEngine.buildViewResult(
            snapshot: snapshot,
            progress: progressStore.data,
            options: options
        )

        viewResult = result

        // Compute zero-scroll paginated columns for Hold-⌘ Peek Overlay (4 compact columns × 16 units)
        let pages = ShortcutSearchEngine.paginateGroupsForOverlay(
            result.groups,
            columnsPerPage: 4,
            maxUnitsPerColumn: 16
        )
        overlayPages = pages
        if overlayPageIndex >= pages.count {
            overlayPageIndex = max(0, pages.count - 1)
        }

        // Keep selectedCategory valid when switching apps
        if let cat = selectedCategory, !result.availableCategories.contains(cat) {
            selectedCategory = nil
        }
        if selectedIndex >= result.flatVisibleItems.count {
            selectedIndex = max(0, result.flatVisibleItems.count - 1)
        }
    }

    // MARK: - Learning & Progress Actions

    func isPinned(_ item: ShortcutItem) -> Bool {
        progressStore.isPinned(item.id)
    }

    func isMastered(_ item: ShortcutItem) -> Bool {
        progressStore.isMastered(item.id)
    }

    func togglePinned(_ item: ShortcutItem) {
        let nowPinned = progressStore.togglePinned(item.id)
        recomputeViewResult()
        showToast(nowPinned ? "已加入「重点练习」：\(item.title)" : "已取消置顶：\(item.title)")
    }

    func toggleMastered(_ item: ShortcutItem) {
        let nowMastered = progressStore.toggleMastered(item.id)
        recomputeViewResult()
        showToast(nowMastered ? "已标为「已记住」并收起：\(item.title)" : "已恢复显示：\(item.title)")
    }

    func restoreAllMasteredForCurrentApp() {
        let ids = viewResult.masteredItems.map(\.id)
        progressStore.resetMastered(for: ids)
        showMasteredDrawer = false
        recomputeViewResult()
        showToast("已恢复本应用全部已记住快捷键")
    }

    // MARK: - Keyboard Navigation & Direct Execution

    func moveSelection(delta: Int) {
        let count = viewResult.flatVisibleItems.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
    }

    var selectedItem: ShortcutItem? {
        let items = viewResult.flatVisibleItems
        guard selectedIndex >= 0, selectedIndex < items.count else { return nil }
        return items[selectedIndex]
    }

    func executeSelected() {
        guard let item = selectedItem else { return }
        executeShortcut(item)
    }

    func togglePinSelected() {
        guard let item = selectedItem else { return }
        togglePinned(item)
    }

    func toggleMasteredSelected() {
        guard let item = selectedItem else { return }
        toggleMastered(item)
    }

    func executeShortcut(_ item: ShortcutItem) {
        guard let app = targetApp else {
            showToast("未找到目标应用窗口")
            return
        }

        progressStore.recordUsage(item.id)
        let pid = app.processIdentifier
        let scannerRef = self.scanner
        let wasSearch = isSearchActive

        // Exit search focus & reactivate target app before triggering menu/keystroke
        if wasSearch {
            searchQuery = ""
            isSearchActive = false
            onRequestDismissSearch?()
        }

        app.activate(options: [])

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.scanQueue.async {
                let ok = scannerRef.executeShortcut(item, targetPID: pid)
                Task { @MainActor in
                    guard let self else { return }
                    if ok {
                        self.showToast("已执行：\(item.title)  \(item.keyCombo.displayString)")
                        self.scanCurrentTargetApp(silent: true)
                    } else {
                        self.showToast("请在 \(self.targetAppName) 中直接按 \(item.keyCombo.displayString)")
                    }
                }
            }
        }
    }

    func showToast(_ message: String) {
        toastWorkItem?.cancel()
        toastMessage = message
        let work = DispatchWorkItem { [weak self] in
            self?.toastMessage = nil
        }
        toastWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }
}
