import AppKit
import SwiftUI
import KeySightCore

struct HUDRootView: View {
    @ObservedObject var viewModel: KeySightViewModel
    @FocusState private var isSearchFieldFocused: Bool

    private var isOverlay: Bool {
        viewModel.displayMode == .peekOverlay
    }

    private var cornerRadius: CGFloat {
        viewModel.appearanceStyle.isLiquidGlass ? 22 : 16
    }

    private var usesNativeLiquidGlass: Bool {
        if #available(macOS 26.0, *) {
            return viewModel.appearanceStyle.isLiquidGlass
        }
        return false
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            HUDSurfaceBackground(
                style: viewModel.appearanceStyle,
                cornerRadius: cornerRadius
            )

            VStack(spacing: 0) {
                headerBar
                Divider().opacity(viewModel.appearanceStyle.isLiquidGlass ? 0.22 : 0.35)

                if !viewModel.isAccessibilityGranted {
                    permissionBanner
                    Divider().opacity(0.25)
                }

                if !isOverlay {
                    searchBar
                    if viewModel.searchQuery.isEmpty && !viewModel.viewResult.availableCategories.isEmpty {
                        categoryPillsBar
                    }
                    Divider().opacity(0.25)
                }

                contentArea

                Divider().opacity(viewModel.appearanceStyle.isLiquidGlass ? 0.20 : 0.30)
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
                                colors: viewModel.appearanceStyle.isLiquidGlass
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
        .preferredColorScheme(viewModel.appearanceStyle == .solidGraphite ? .dark : nil)
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
                    MiniToggleChip(label: "免触控板推荐", icon: "sparkles", isOn: $viewModel.includeSupplemental)
                    MiniToggleChip(label: "隐藏已记住", icon: "eye.slash", isOn: $viewModel.hideMastered)
                    appearancePickerButton(showLabel: true)

                    Button {
                        viewModel.onRequestPinFromOverlay?()
                    } label: {
                        Label("钉住悬浮窗", systemImage: "pin.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                            .padding(.horizontal, 10)
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
                        viewModel.scanCurrentTargetApp(silent: false)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.primary.opacity(0.06)))
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
                            .background(Circle().fill(Color.primary.opacity(0.06)))
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
        } label: {
            if showLabel {
                HStack(spacing: 4) {
                    Image(systemName: viewModel.appearanceStyle.systemSymbol)
                        .font(.system(size: 10, weight: .semibold))
                    Text(viewModel.appearanceStyle.displayName)
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
                Image(systemName: viewModel.appearanceStyle.systemSymbol)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(viewModel.appearanceStyle.isLiquidGlass ? Color.accentColor : Color.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("切换悬浮窗外观材质（当前：\(viewModel.appearanceStyle.displayName)）")
    }

    // MARK: - Permission Banner

    private var permissionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12))
            Text("尚未授予辅助功能权限，暂无法读取当前应用实时菜单。")
                .font(.system(size: 11.5))
                .foregroundStyle(.primary.opacity(0.9))
                .lineLimit(2)
            Spacer()
            Button("去授权") {
                viewModel.requestAccessibilityPermission()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
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
                            .fill(Color.primary.opacity(0.06))
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(viewModel.isSearchActive ? 0.07 : 0.03))
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
                .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.8))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.07))
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

    /// Wide multi-column cheat-sheet grid for Hold-⌘ Peek Overlay
    private var overlayGridContent: some View {
        ScrollView(.vertical, showsIndicators: true) {
            let columns = [
                GridItem(.adaptive(minimum: 270, maximum: 340), spacing: 12, alignment: .top)
            ]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(viewModel.viewResult.groups) { group in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            if group.title == ShortcutSearchEngine.pinnedCategoryTitle {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.orange)
                            }
                            Text(group.title)
                                .font(.system(size: 11.5, weight: .bold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(group.items.count)")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 2)

                        VStack(spacing: 2) {
                            ForEach(group.items) { item in
                                ShortcutRowView(
                                    item: item,
                                    isPinned: viewModel.isPinned(item),
                                    isMastered: viewModel.isMastered(item),
                                    isSelected: false,
                                    isHovered: viewModel.hoveredItemID == item.id,
                                    compact: true,
                                    glassStyle: viewModel.appearanceStyle.isLiquidGlass,
                                    onHoverChanged: { hovering in
                                        if hovering {
                                            viewModel.hoveredItemID = item.id
                                        } else if viewModel.hoveredItemID == item.id {
                                            viewModel.hoveredItemID = nil
                                        }
                                    },
                                    onExecute: { viewModel.executeShortcut(item) },
                                    onTogglePin: { viewModel.togglePinned(item) },
                                    onToggleMastered: { viewModel.toggleMastered(item) }
                                )
                            }
                        }
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.045))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.75)
                    )
                }
            }
            .padding(14)
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
                                    isHovered: viewModel.hoveredItemID == item.id,
                                    compact: false,
                                    glassStyle: viewModel.appearanceStyle.isLiquidGlass,
                                    onHoverChanged: { hovering in
                                        if hovering {
                                            viewModel.hoveredItemID = item.id
                                        } else if viewModel.hoveredItemID == item.id {
                                            viewModel.hoveredItemID = nil
                                        }
                                    },
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
                                isHovered: viewModel.hoveredItemID == item.id,
                                compact: false,
                                glassStyle: viewModel.appearanceStyle.isLiquidGlass,
                                onHoverChanged: { hovering in
                                    if hovering {
                                        viewModel.hoveredItemID = item.id
                                    } else if viewModel.hoveredItemID == item.id {
                                        viewModel.hoveredItemID = nil
                                    }
                                },
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
                Text("松开 ⌘ 自动收起 · 看到目标键可直接连按触发 · 点右上角可钉住常驻")
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
