import AppKit
import SwiftUI
import KeySightCore

struct HUDRootView: View {
    @ObservedObject var viewModel: KeySightViewModel
    @FocusState private var isSearchFieldFocused: Bool

    private var isOverlay: Bool {
        viewModel.displayMode == .peekOverlay
    }

    private var activeStyle: HUDAppearanceStyle {
        viewModel.effectiveAppearanceStyle
    }

    private var cornerRadius: CGFloat {
        switch activeStyle {
        case .liquidGlassClear: return 26
        case .liquidGlass: return 24
        case .frostedHUD, .solidGraphite: return 16
        }
    }

    private var usesNativeLiquidGlass: Bool {
        if #available(macOS 26.0, *) {
            return activeStyle.isLiquidGlass
        }
        return false
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            HUDSurfaceBackground(
                style: activeStyle,
                cornerRadius: cornerRadius
            )

            VStack(spacing: 0) {
                headerBar
                Divider().opacity(activeStyle.isLiquidGlass ? 0.22 : 0.35)

                if !viewModel.isAccessibilityGranted {
                    permissionBanner
                    Divider().opacity(0.25)
                }

                if isOverlay {
                    overlayControlStrip
                    Divider().opacity(activeStyle.isLiquidGlass ? 0.16 : 0.25)
                }

                if !isOverlay {
                    searchBar
                    if viewModel.searchQuery.isEmpty && !viewModel.viewResult.availableCategories.isEmpty {
                        categoryPillsBar
                    }
                    Divider().opacity(0.25)
                }

                contentArea

                Divider().opacity(activeStyle.isLiquidGlass ? 0.20 : 0.30)
                footerBar
            }

            if let toast = viewModel.toastMessage {
                Text(toast)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.black.opacity(0.78))
                    )
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                    .padding(.bottom, 42)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            Group {
                if !usesNativeLiquidGlass {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: activeStyle.isLiquidGlass
                                    ? [Color.white.opacity(0.45), Color.white.opacity(0.14)]
                                    : [Color.primary.opacity(0.18), Color.primary.opacity(0.12)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
            }
        )
        .preferredColorScheme(activeStyle == .solidGraphite ? .dark : nil)
        .animation(.easeOut(duration: 0.16), value: viewModel.toastMessage)
        .onAppear {
            viewModel.onRequestFocusSearch = {
                DispatchQueue.main.async {
                    isSearchFieldFocused = true
                }
            }
        }
        .onChange(of: viewModel.isSearchActive) { _, active in
            isSearchFieldFocused = active
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 10) {
            if let icon = viewModel.targetAppIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: "command.square.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(viewModel.targetAppName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)

                    // Context badge
                    HStack(spacing: 3) {
                        Image(systemName: viewModel.focusContext.systemSymbol)
                            .font(.system(size: 9.5, weight: .semibold))
                        Text(viewModel.focusContext.displayLabel)
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.accentColor.opacity(0.13))
                    )
                }

                HStack(spacing: 8) {
                    Text("可用 \(viewModel.viewResult.totalAvailableCount) 项")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    if viewModel.viewResult.totalMasteredCount > 0 {
                        Text("· 已记住 \(viewModel.viewResult.totalMasteredCount)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.green)
                    }

                    if let win = viewModel.windowTitle, isOverlay {
                        Text("· \(win)")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }

            Spacer(minLength: 8)

            if isOverlay {
                HStack(spacing: 6) {
                    MiniToggleChip(label: "仅可用", icon: "checkmark.seal", isOn: $viewModel.onlyEnabled)
                    MiniToggleChip(
                        label: viewModel.viewResult.hiddenBasicCount > 0 ? "隐基础键(\(viewModel.viewResult.hiddenBasicCount))" : "隐基础键",
                        icon: "line.3.horizontal.decrease.circle",
                        isOn: $viewModel.hideBasicShortcuts
                    )
                    MiniToggleChip(label: "免触控板", icon: "sparkles", isOn: $viewModel.includeSupplemental)
                    MiniToggleChip(label: "隐已记住", icon: "eye.slash", isOn: $viewModel.hideMastered)
                    appearancePickerButton(showLabel: false)

                    Button {
                        viewModel.onRequestPinFromOverlay?()
                    } label: {
                        Label("钉住", systemImage: "pin.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            } else {
                HStack(spacing: 5) {
                    MiniToggleChip(label: "仅可用", icon: "checkmark.seal", isOn: $viewModel.onlyEnabled)
                        .help("仅显示当前界面下实际可用的快捷键（过滤灰色不可用菜单项）")

                    appearancePickerButton(showLabel: false)

                    Button {
                        viewModel.scanCurrentTargetApp(silent: false, forceRefresh: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .adaptiveGlassCircle(enabled: activeStyle.isLiquidGlass)
                    }
                    .buttonStyle(.plain)
                    .help("立即刷新当前界面快捷键")

                    Button {
                        viewModel.onRequestCloseHUD?()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .adaptiveGlassCircle(enabled: activeStyle.isLiquidGlass)
                    }
                    .buttonStyle(.plain)
                    .help("隐藏悬浮窗 (⌥⇧K)")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func appearancePickerButton(showLabel: Bool) -> some View {
        Menu {
            ForEach(HUDAppearanceStyle.allCases) { style in
                Button {
                    viewModel.appearanceStyle = style
                    viewModel.showToast("已切换外观：\(style.displayName)")
                } label: {
                    HStack {
                        Label(style.menuDescription, systemImage: style.systemSymbol)
                        if viewModel.appearanceStyle == style {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            Divider()

            Button {
                viewModel.ecoPinnedMode.toggle()
                viewModel.showToast(viewModel.ecoPinnedMode ? "已开启常驻省电模式（仅长按 ⌘ 时启用液态玻璃）" : "已关闭常驻省电模式")
            } label: {
                HStack {
                    Label("常驻省电模式（推荐）", systemImage: "leaf.fill")
                    if viewModel.ecoPinnedMode {
                        Image(systemName: "checkmark")
                    }
                }
            }
        } label: {
            if showLabel {
                HStack(spacing: 4) {
                    Image(systemName: activeStyle.systemSymbol)
                        .font(.system(size: 10, weight: .semibold))
                    Text(activeStyle.displayName)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.primary.opacity(0.86))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.75)
                )
            } else {
                Image(systemName: activeStyle.systemSymbol)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(activeStyle.isLiquidGlass ? Color.accentColor : Color.secondary)
                    .frame(width: 24, height: 24)
                    .adaptiveGlassCircle(enabled: activeStyle.isLiquidGlass)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("切换悬浮窗外观材质与省电模式（当前：\(activeStyle.displayName)）")
    }

    // MARK: - Permission Banner

    private var permissionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text("尚未识别到辅助功能授权，暂无法读取当前应用实时菜单。")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.92))
                    .lineLimit(2)
                Text("若系统设置中已勾选仍提示，点右侧「重置授权」即可修复更新后的签名残留。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            HStack(spacing: 5) {
                Button("重置授权") {
                    viewModel.resetAndRequestAccessibilityPermission()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("清理更新前残留的旧签名授权记录，然后重新授权")

                Button("去授权") {
                    viewModel.requestAccessibilityPermission()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.11))
    }

    // MARK: - Search Bar (Pinned & Search Mode)

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(viewModel.isSearchActive ? Color.accentColor : Color.secondary)

            TextField("搜索快捷键、中文功能或按键 (如 cmd shift t)…", text: $viewModel.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($isSearchFieldFocused)
                .onTapGesture {
                    if !viewModel.isSearchActive {
                        NotificationCenter.default.post(name: .ksRequestActivateSearch, object: nil)
                    }
                }

            if !viewModel.searchQuery.isEmpty {
                Button {
                    viewModel.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else if !viewModel.isSearchActive {
                Text("⌥⇧F")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .adaptiveGlassCapsule(
            enabled: activeStyle.isLiquidGlass,
            interactive: true,
            tint: viewModel.isSearchActive ? Color.accentColor.opacity(0.18) : nil
        )
        .padding(.horizontal, activeStyle.isLiquidGlass ? 10 : 0)
        .padding(.top, activeStyle.isLiquidGlass ? 8 : 0)
        .padding(.bottom, activeStyle.isLiquidGlass ? 4 : 0)
    }

    // MARK: - Category Filter Pills

    private var categoryPillsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                categoryPill(title: "全部", isSelected: viewModel.selectedCategory == nil) {
                    viewModel.selectedCategory = nil
                }

                ForEach(viewModel.viewResult.availableCategories, id: \.self) { category in
                    categoryPill(
                        title: category,
                        isSelected: viewModel.selectedCategory == category
                    ) {
                        viewModel.selectedCategory = (viewModel.selectedCategory == category) ? nil : category
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
    }

    private func categoryPill(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.86))
                .padding(.horizontal, 10)
                .padding(.vertical, 4.5)
                .adaptiveGlassCapsule(
                    enabled: activeStyle.isLiquidGlass,
                    interactive: true,
                    tint: isSelected ? Color.accentColor : nil
                )
                .background(
                    Group {
                        if !activeStyle.isLiquidGlass && isSelected {
                            Capsule(style: .continuous).fill(Color.accentColor)
                        }
                    }
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Main Content Area

    @ViewBuilder
    private var contentArea: some View {
        if !viewModel.isAccessibilityGranted && viewModel.viewResult.groups.isEmpty {
            PermissionView(
                onOpenSettings: { viewModel.requestAccessibilityPermission() },
                onRecheck: { viewModel.refreshPermissionStatus() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.showMasteredDrawer {
            masteredDrawerView
        } else if viewModel.viewResult.groups.isEmpty {
            emptyStateView
        } else if isOverlay {
            overlayGridContent
        } else {
            pinnedListContent
        }
    }

    // MARK: - Hold-⌘ Live Modifier Chord & Zero-Trackpad Strip

    private var overlayControlStrip: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Text("叠加筛选")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                modifierBadge(symbol: "⌘", active: true)
                modifierBadge(symbol: "⇧", active: viewModel.liveHeldModifiers.contains(.shift))
                modifierBadge(symbol: "⌥", active: viewModel.liveHeldModifiers.contains(.option))
                modifierBadge(symbol: "⌃", active: viewModel.liveHeldModifiers.contains(.control))

                if let chord = viewModel.activeChordFilter {
                    Text("仅显示 \(chord.symbols.joined()) 组合（\(viewModel.viewResult.flatVisibleItems.count) 项）")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.leading, 4)
                } else {
                    Text("按住 ⇧ / ⌥ / ⌃ 即时缩窄")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 2)
                }
            }

            Spacer(minLength: 8)

            // Instant jump-to-search hint
            HStack(spacing: 4) {
                Text("按")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                miniKeyBadge("Space")
                Text("或")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                miniKeyBadge("/")
                Text("秒进搜索")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.85))
            }

            // Keyboard paging indicator when more than 1 page
            if viewModel.overlayPages.count > 1 {
                Divider().frame(height: 14).opacity(0.35)

                HStack(spacing: 6) {
                    Button {
                        viewModel.stepOverlayPage(delta: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 20, height: 20)
                            .adaptiveGlassCircle(enabled: viewModel.appearanceStyle.isLiquidGlass)
                    }
                    .buttonStyle(.plain)

                    Text("第 \(viewModel.overlayPageIndex + 1) / \(viewModel.overlayPages.count) 页")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()

                    HStack(spacing: 4) {
                        ForEach(0..<viewModel.overlayPages.count, id: \.self) { idx in
                            Circle()
                                .fill(idx == viewModel.overlayPageIndex ? Color.accentColor : Color.primary.opacity(0.22))
                                .frame(width: idx == viewModel.overlayPageIndex ? 6.5 : 5, height: idx == viewModel.overlayPageIndex ? 6.5 : 5)
                                .onTapGesture {
                                    viewModel.overlayPageIndex = idx
                                }
                        }
                    }

                    Button {
                        viewModel.stepOverlayPage(delta: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 20, height: 20)
                            .adaptiveGlassCircle(enabled: viewModel.appearanceStyle.isLiquidGlass)
                    }
                    .buttonStyle(.plain)

                    miniKeyBadge("← →")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private func modifierBadge(symbol: String, active: Bool) -> some View {
        Text(symbol)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(active ? Color.white : Color.secondary)
            .frame(width: 24, height: 21)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(active ? Color.accentColor : Color.primary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(active ? Color.white.opacity(0.35) : Color.primary.opacity(0.12), lineWidth: 0.75)
            )
    }

    private func miniKeyBadge(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary.opacity(0.9))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .fill(Color.primary.opacity(0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.6)
            )
    }

    /// Zero-scroll paginated 4-column layout for Hold-⌘ Peek Overlay
    private var overlayGridContent: some View {
        Group {
            if let page = viewModel.currentOverlayPage {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(page.columns) { column in
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(column.groups) { group in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 5) {
                                        if group.title == ShortcutSearchEngine.pinnedCategoryTitle {
                                            Image(systemName: "star.fill")
                                                .font(.system(size: 9.5))
                                                .foregroundStyle(.orange)
                                        }
                                        Text(group.title)
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        Spacer(minLength: 4)
                                        Text("\(group.items.count)")
                                            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.bottom, 1)

                                    VStack(spacing: 1.5) {
                                        ForEach(group.items) { item in
                                            ShortcutRowView(
                                                item: item,
                                                isPinned: viewModel.isPinned(item),
                                                isMastered: viewModel.isMastered(item),
                                                isSelected: false,
                                                compact: true,
                                                glassStyle: activeStyle.isLiquidGlass,
                                                onExecute: { viewModel.executeShortcut(item) },
                                                onTogglePin: { viewModel.togglePinned(item) },
                                                onToggleMastered: { viewModel.toggleMastered(item) }
                                            )
                                        }
                                    }
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.primary.opacity(activeStyle.isLiquidGlass ? 0.055 : 0.045))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
                                )
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                emptyStateView
            }
        }
    }

    /// Single-column keyboard-navigable list for Pinned HUD & Search Mode
    private var pinnedListContent: some View {
        let flatItems = viewModel.viewResult.flatVisibleItems
        let selectedItemID = (viewModel.isSearchActive && viewModel.selectedIndex < flatItems.count)
            ? flatItems[viewModel.selectedIndex].id
            : nil

        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(viewModel.viewResult.groups) { group in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                if group.title == ShortcutSearchEngine.pinnedCategoryTitle {
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.orange)
                                }
                                Text(group.title)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(group.items.count)")
                                    .font(.system(size: 10, design: .rounded))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.top, 2)

                            ForEach(group.items) { item in
                                ShortcutRowView(
                                    item: item,
                                    isPinned: viewModel.isPinned(item),
                                    isMastered: viewModel.isMastered(item),
                                    isSelected: selectedItemID == item.id,
                                    compact: false,
                                    glassStyle: activeStyle.isLiquidGlass,
                                    onExecute: { viewModel.executeShortcut(item) },
                                    onTogglePin: { viewModel.togglePinned(item) },
                                    onToggleMastered: { viewModel.toggleMastered(item) }
                                )
                                .id(item.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .onChange(of: viewModel.selectedIndex) { _, _ in
                if let id = selectedItemID {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    private var masteredDrawerView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("已记住的快捷键（\(viewModel.viewResult.masteredItems.count)）", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.green)
                Spacer()
                if !viewModel.viewResult.masteredItems.isEmpty {
                    Button("全部恢复显示") {
                        viewModel.restoreAllMasteredForCurrentApp()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                Button("返回") {
                    viewModel.showMasteredDrawer = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().opacity(0.25)

            if viewModel.viewResult.masteredItems.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text("这个应用还没有标记「已记住」的快捷键")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    Text("悬停任意快捷键点 ✓，或在搜索模式按 ⌘M 即可收起已熟练项。")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 4) {
                        ForEach(viewModel.viewResult.masteredItems) { item in
                            ShortcutRowView(
                                item: item,
                                isPinned: viewModel.isPinned(item),
                                isMastered: true,
                                isSelected: false,
                                compact: false,
                                glassStyle: activeStyle.isLiquidGlass,
                                onExecute: { viewModel.executeShortcut(item) },
                                onTogglePin: { viewModel.togglePinned(item) },
                                onToggleMastered: { viewModel.toggleMastered(item) }
                            )
                        }
                    }
                    .padding(10)
                }
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: viewModel.searchQuery.isEmpty ? "checkmark.seal.fill" : "magnifyingglass")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(viewModel.searchQuery.isEmpty ? "当前筛选下暂无未记住的快捷键" : "未找到匹配「\(viewModel.searchQuery)」的快捷键")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            if viewModel.searchQuery.isEmpty && viewModel.viewResult.totalMasteredCount > 0 {
                Button("查看已记住的 \(viewModel.viewResult.totalMasteredCount) 项") {
                    viewModel.showMasteredDrawer = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Footer Bar

    private var footerBar: some View {
        HStack(spacing: 10) {
            if viewModel.isSearchActive {
                Text("↑↓ 选择 · ↩ 执行 · ⌘P 置顶 · ⌘M 已记住 · Esc 退出")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if isOverlay {
                Text("零触控板：按住 ⇧/⌥/⌃ 缩窄组合 · 按 Space 或 / 秒进搜索 · ← → 翻页 · 看到目标直接补按触发 · 松开 ⌘ 收起")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                HStack(spacing: 6) {
                    Text("长按 ⌘ 全览")
                    Text("·")
                    Text("⌥⇧F 搜索执行")
                    Text("·")
                    Text("⌥⇧K 收起")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 6)

            if !isOverlay {
                Button {
                    viewModel.includeSupplemental.toggle()
                } label: {
                    Image(systemName: viewModel.includeSupplemental ? "sparkles" : "sparkles")
                        .font(.system(size: 10.5))
                        .foregroundStyle(viewModel.includeSupplemental ? Color.accentColor : Color.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help(viewModel.includeSupplemental ? "已开启系统/免触控板补充快捷键" : "点击开启系统/免触控板补充快捷键")
            }

            Button {
                viewModel.showMasteredDrawer.toggle()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                    Text("已记住 \(viewModel.viewResult.totalMasteredCount)")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .foregroundStyle(viewModel.showMasteredDrawer ? Color.white : Color.green)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous)
                        .fill(viewModel.showMasteredDrawer ? Color.green : Color.green.opacity(0.13))
                )
            }
            .buttonStyle(.plain)
            .help("查看或恢复已标记为「已记住」的快捷键")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

extension Notification.Name {
    static let ksRequestActivateSearch = Notification.Name("com.xinque.keysight.activateSearch")
}
