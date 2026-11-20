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
    @Published var hoveredItemID: String? = nil
    @Published var showMasteredDrawer: Bool = false
    @Published var toastMessage: String?

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
            onAppearanceChanged?(appearanceStyle)
            onPreferenceChanged?()
        }
    }

    var onPreferenceChanged: (() -> Void)?
    var onAppearanceChanged: ((HUDAppearanceStyle) -> Void)?
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
    private var scanGeneration: Int = 0
    private var workspaceObserver: NSObjectProtocol?
    private var liveRefreshTimer: Timer?
    private var permissionTimer: Timer?
    private var toastWorkItem: DispatchWorkItem?

    private enum Keys {
        static let onlyEnabled = "ks.onlyEnabled"
        static let includeSupplemental = "ks.includeSupplemental"
        static let hideMastered = "ks.hideMastered"
        static let commandHoldEnabled = "ks.commandHoldEnabled"
        static let commandHoldDelay = "ks.commandHoldDelay"
        static let appearanceStyle = "ks.appearanceStyle"
    }

    init() {
        let ud = UserDefaults.standard
        self.onlyEnabled = ud.object(forKey: Keys.onlyEnabled) as? Bool ?? true
        self.includeSupplemental = ud.object(forKey: Keys.includeSupplemental) as? Bool ?? true
        self.hideMastered = ud.object(forKey: Keys.hideMastered) as? Bool ?? true
        self.isCommandHoldEnabled = ud.object(forKey: Keys.commandHoldEnabled) as? Bool ?? true
        let savedDelay = ud.double(forKey: Keys.commandHoldDelay)
        self.commandHoldDelay = savedDelay > 0.1 ? savedDelay : 0.45
        if let savedStyleRaw = ud.string(forKey: Keys.appearanceStyle),
           let savedStyle = HUDAppearanceStyle(rawValue: savedStyleRaw) {
            self.appearanceStyle = savedStyle
        } else {
            self.appearanceStyle = .liquidGlass
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

        // Gentle live refresh when pinned HUD is visible (catches tab/focus/menu-enabled updates)
        liveRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isHUDVisible, !self.isSearchActive, self.isAccessibilityGranted else { return }
                self.scanCurrentTargetApp(silent: true)
            }
        }

        // Poll accessibility permission until granted so onboarding resolves automatically
        if !isAccessibilityGranted {
            startPermissionPolling()
        }
    }

    func stopMonitoring() {
        if let obs = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        liveRefreshTimer?.invalidate()
        permissionTimer?.invalidate()
    }

    private func startPermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else {
                    timer.invalidate()
                    return
                }
                let granted = AccessibilityScanner.isAccessibilityTrusted(prompt: false)
                if granted {
                    self.isAccessibilityGranted = true
                    timer.invalidate()
                    self.permissionTimer = nil
                    self.captureFrontmostAppIfExternal()
                    self.scanCurrentTargetApp(silent: false)
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

        scanCurrentTargetApp(silent: !appChanged)
    }

    func scanCurrentTargetApp(silent: Bool = false) {
        if targetApp == nil {
            captureFrontmostAppIfExternal()
        }
        guard let app = targetApp else { return }

        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier ?? ""
        let appName = app.localizedName ?? "当前应用"

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
                self.currentSnapshot = snapshot
                self.windowTitle = snapshot.windowTitle
                self.focusContext = snapshot.focusContext
                self.recomputeViewResult()
            }
        }
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
            selectedCategory: selectedCategory
        )

        let result = ShortcutSearchEngine.buildViewResult(
            snapshot: snapshot,
            progress: progressStore.data,
            options: options
        )

        viewResult = result

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
