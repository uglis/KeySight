import Foundation

public struct ShortcutFilterOptions: Sendable {
    public var query: String
    public var onlyEnabled: Bool
    public var includeSupplemental: Bool
    public var hideMastered: Bool
    public var hideBasicShortcuts: Bool
    public var requiredModifiers: KeyModifiers?
    public var selectedCategory: String?

    public init(
        query: String = "",
        onlyEnabled: Bool = true,
        includeSupplemental: Bool = true,
        hideMastered: Bool = true,
        hideBasicShortcuts: Bool = true,
        requiredModifiers: KeyModifiers? = nil,
        selectedCategory: String? = nil
    ) {
        self.query = query
        self.onlyEnabled = onlyEnabled
        self.includeSupplemental = includeSupplemental
        self.hideMastered = hideMastered
        self.hideBasicShortcuts = hideBasicShortcuts
        self.requiredModifiers = requiredModifiers
        self.selectedCategory = selectedCategory
    }
}

public struct OverlayColumn: Identifiable, Sendable {
    public let id: String
    public let groups: [ShortcutGroup]

    public init(id: String, groups: [ShortcutGroup]) {
        self.id = id
        self.groups = groups
    }
}

public struct OverlayPage: Identifiable, Sendable {
    public let id: Int
    public let pageIndex: Int
    public let columns: [OverlayColumn]

    public init(pageIndex: Int, columns: [OverlayColumn]) {
        self.id = pageIndex
        self.pageIndex = pageIndex
        self.columns = columns
    }
}

public struct ShortcutViewResult: Sendable {
    public let groups: [ShortcutGroup]
    public let flatVisibleItems: [ShortcutItem]
    public let masteredItems: [ShortcutItem]
    public let availableCategories: [String]
    public let totalAvailableCount: Int
    public let totalMasteredCount: Int
    public let hiddenBasicCount: Int

    public init(
        groups: [ShortcutGroup],
        flatVisibleItems: [ShortcutItem],
        masteredItems: [ShortcutItem],
        availableCategories: [String],
        totalAvailableCount: Int,
        totalMasteredCount: Int,
        hiddenBasicCount: Int = 0
    ) {
        self.groups = groups
        self.flatVisibleItems = flatVisibleItems
        self.masteredItems = masteredItems
        self.availableCategories = availableCategories
        self.totalAvailableCount = totalAvailableCount
        self.totalMasteredCount = totalMasteredCount
        self.hiddenBasicCount = hiddenBasicCount
    }
}

public enum ShortcutSearchEngine {
    public static let pinnedCategoryTitle = "重点练习"

    /// Universal macOS muscle-memory shortcuts that appear in almost every app.
    /// Users can hide these in one click to cut ~25% visual clutter in the HUD.
    public static let universalBasicSignatures: Set<String> = {
        let combos: [(KeyModifiers, String)] = [
            ([.command], "C"),        // Copy
            ([.command], "V"),        // Paste
            ([.command], "X"),        // Cut
            ([.command], "Z"),        // Undo
            ([.command, .shift], "Z"),// Redo
            ([.command], "A"),        // Select All
            ([.command], "S"),        // Save
            ([.command], "P"),        // Print
            ([.command], "Q"),        // Quit
            ([.command], "W"),        // Close
            ([.command], "M"),        // Minimize
            ([.command], "H"),        // Hide
            ([.command], "N"),        // New
            ([.command], "O"),        // Open
            ([.command], "F")         // Find
        ]
        return Set(combos.map { KeyCombo(modifiers: $0.0, keyDisplay: $0.1).normalizedSignature })
    }()

    public static func isBasicShortcut(_ item: ShortcutItem) -> Bool {
        // Context tips (e.g., ⌃A/⌃E/Space) are anti-trackpad tips, never treated as basic clutter
        if item.source == .contextTip { return false }
        return universalBasicSignatures.contains(item.keyCombo.normalizedSignature)
    }

    /// Merges live menu shortcuts with context/app/system supplemental shortcuts, deduplicating by key signature.
    public static func mergeShortcuts(
        snapshot: AppScanSnapshot,
        includeSupplemental: Bool
    ) -> [ShortcutItem] {
        var merged: [ShortcutItem] = []
        var seenSignatures: Set<String> = []

        // 1. Live menu items first (authoritative for the current UI state & supports direct AXPress)
        for item in snapshot.liveMenuShortcuts {
            let sig = item.keyCombo.normalizedSignature
            if !seenSignatures.contains(sig) {
                seenSignatures.insert(sig)
                merged.append(item)
            }
        }

        // 2. Context-aware & app/system supplemental items (only add shortcuts not already exposed in menu bar)
        if includeSupplemental {
            let supplemental = SupplementalShortcuts.shortcuts(
                for: snapshot.bundleID,
                focusContext: snapshot.focusContext
            )
            for item in supplemental {
                let sig = item.keyCombo.normalizedSignature
                if !seenSignatures.contains(sig) {
                    seenSignatures.insert(sig)
                    merged.append(item)
                }
            }
        }

        return merged
    }

    /// Produces filtered, ranked, and grouped results for display in either Overlay or Pinned HUD mode.
    public static func buildViewResult(
        snapshot: AppScanSnapshot,
        progress: ShortcutProgressData,
        options: ShortcutFilterOptions
    ) -> ShortcutViewResult {
        let allMerged = mergeShortcuts(
            snapshot: snapshot,
            includeSupplemental: options.includeSupplemental
        )

        // Filter enabled status first
        let enabledFiltered = options.onlyEnabled
            ? allMerged.filter { $0.isEnabled }
            : allMerged

        let masteredAll = enabledFiltered.filter { progress.masteredIDs.contains($0.id) }
        let totalAvailableCount = enabledFiltered.count
        let totalMasteredCount = masteredAll.count

        let trimmedQuery = options.query.trimmingCharacters(in: .whitespacesAndNewlines)

        // Separate mastered items if hideMastered is enabled (unless actively searching)
        let afterMastered: [ShortcutItem]
        if options.hideMastered && trimmedQuery.isEmpty {
            afterMastered = enabledFiltered.filter { !progress.masteredIDs.contains($0.id) }
        } else {
            afterMastered = enabledFiltered
        }

        // Optionally hide universal basic shortcuts (unless explicitly pinned or actively searching)
        var hiddenBasicCount = 0
        let afterBasics: [ShortcutItem]
        if options.hideBasicShortcuts && trimmedQuery.isEmpty {
            var kept: [ShortcutItem] = []
            for item in afterMastered {
                if !progress.pinnedIDs.contains(item.id) && isBasicShortcut(item) {
                    hiddenBasicCount += 1
                } else {
                    kept.append(item)
                }
            }
            afterBasics = kept
        } else {
            afterBasics = afterMastered
        }

        // Apply live Which-Key modifier chord filter (when user holds ⌘ + additional ⇧/⌥/⌃)
        let activePool: [ShortcutItem]
        if let required = options.requiredModifiers, !required.isEmpty, trimmedQuery.isEmpty {
            activePool = afterBasics.filter { $0.keyCombo.modifiers.isSuperset(of: required) }
        } else {
            activePool = afterBasics
        }

        // Compute ordered categories before category-pill filtering
        let orderedCategories = computeOrderedCategories(
            from: activePool,
            pinnedIDs: progress.pinnedIDs
        )

        // Apply search query if present
        let searched: [ShortcutItem]
        if trimmedQuery.isEmpty {
            searched = activePool
        } else {
            let tokens = tokenizeQuery(trimmedQuery)
            searched = activePool
                .compactMap { item -> (ShortcutItem, Int)? in
                    let score = matchScore(item: item, tokens: tokens, progress: progress)
                    return score > 0 ? (item, score) : nil
                }
                .sorted { lhs, rhs in
                    if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                    return lhs.0.title < rhs.0.title
                }
                .map(\.0)
        }

        // Apply category pill filter (only when not searching)
        let categoryFiltered: [ShortcutItem]
        if let selectedCat = options.selectedCategory, trimmedQuery.isEmpty {
            if selectedCat == pinnedCategoryTitle {
                categoryFiltered = searched.filter { progress.pinnedIDs.contains($0.id) }
            } else {
                categoryFiltered = searched.filter { $0.category == selectedCat }
            }
        } else {
            categoryFiltered = searched
        }

        // Group results cleanly
        let groups: [ShortcutGroup]
        if !trimmedQuery.isEmpty {
            groups = categoryFiltered.isEmpty
                ? []
                : [ShortcutGroup(title: "搜索结果（\(categoryFiltered.count)）", items: categoryFiltered)]
        } else {
            groups = groupItems(
                categoryFiltered,
                pinnedIDs: progress.pinnedIDs,
                usageCounts: progress.usageCounts,
                selectedCategory: options.selectedCategory
            )
        }

        let flatVisible = groups.flatMap(\.items)

        return ShortcutViewResult(
            groups: groups,
            flatVisibleItems: flatVisible,
            masteredItems: masteredAll,
            availableCategories: orderedCategories,
            totalAvailableCount: totalAvailableCount,
            totalMasteredCount: totalMasteredCount,
            hiddenBasicCount: hiddenBasicCount
        )
    }

    /// Packs shortcut groups into fixed-capacity columns & pages so the Hold-⌘ Overlay
    /// NEVER needs trackpad scrolling — users can scan 1 full screen or flip pages with ← / →.
    public static func paginateGroupsForOverlay(
        _ groups: [ShortcutGroup],
        columnsPerPage: Int = 3,
        maxUnitsPerColumn: Int = 18
    ) -> [OverlayPage] {
        guard !groups.isEmpty else { return [] }
        let safeCols = max(1, columnsPerPage)
        let safeCap = max(6, maxUnitsPerColumn)

        // Header + card padding costs ~2 row units; each shortcut row costs 1 unit
        let headerCost = 2

        var allColumns: [OverlayColumn] = []
        var currentColGroups: [ShortcutGroup] = []
        var usedUnits = 0

        func flushColumn() {
            guard !currentColGroups.isEmpty else { return }
            let colID = "col-\(allColumns.count)"
            allColumns.append(OverlayColumn(id: colID, groups: currentColGroups))
            currentColGroups = []
            usedUnits = 0
        }

        for group in groups {
            var remaining = group.items
            var partIndex = 0

            while !remaining.isEmpty {
                let remainingSpace = safeCap - usedUnits
                // Need at least header + 2 items to start a group in the current column (unless column is empty)
                if !currentColGroups.isEmpty && remainingSpace < headerCost + min(2, remaining.count) {
                    flushColumn()
                }

                let availableItemSlots = max(1, (safeCap - usedUnits) - headerCost)
                let sliceCount = min(remaining.count, availableItemSlots)
                let slice = Array(remaining.prefix(sliceCount))
                remaining.removeFirst(sliceCount)

                let sliceTitle = partIndex == 0 ? group.title : "\(group.title)（续）"
                currentColGroups.append(ShortcutGroup(title: sliceTitle, items: slice))
                usedUnits += headerCost + sliceCount
                partIndex += 1

                if !remaining.isEmpty {
                    flushColumn()
                }
            }
        }
        flushColumn()

        // Chunk columns into pages of `safeCols` columns each
        var pages: [OverlayPage] = []
        var idx = 0
        while idx < allColumns.count {
            let end = min(idx + safeCols, allColumns.count)
            let pageCols = Array(allColumns[idx..<end])
            pages.append(OverlayPage(pageIndex: pages.count, columns: pageCols))
            idx = end
        }
        return pages
    }

    private static func computeOrderedCategories(
        from items: [ShortcutItem],
        pinnedIDs: Set<String>
    ) -> [String] {
        var result: [String] = []
        if items.contains(where: { pinnedIDs.contains($0.id) }) {
            result.append(pinnedCategoryTitle)
        }

        var contextCats: [String] = []
        var appSuppCats: [String] = []
        var liveMenuCats: [String] = []
        var systemCats: [String] = []

        func appendUnique(_ cat: String, to list: inout [String]) {
            if !list.contains(cat) { list.append(cat) }
        }

        for item in items {
            switch item.source {
            case .contextTip:
                appendUnique(item.category, to: &contextCats)
            case .appSupplemental:
                appendUnique(item.category, to: &appSuppCats)
            case .liveMenu:
                appendUnique(item.category, to: &liveMenuCats)
            case .systemGlobal:
                appendUnique(item.category, to: &systemCats)
            }
        }

        result.append(contentsOf: contextCats)
        result.append(contentsOf: appSuppCats)
        result.append(contentsOf: liveMenuCats)
        result.append(contentsOf: systemCats)
        return result
    }

    private static func groupItems(
        _ items: [ShortcutItem],
        pinnedIDs: Set<String>,
        usageCounts: [String: Int],
        selectedCategory: String?
    ) -> [ShortcutGroup] {
        var groups: [ShortcutGroup] = []

        if selectedCategory == pinnedCategoryTitle {
            let pinned = items.filter { pinnedIDs.contains($0.id) }
            if !pinned.isEmpty {
                groups.append(ShortcutGroup(title: pinnedCategoryTitle, items: pinned))
            }
            return groups
        }

        var remaining = items
        if selectedCategory == nil {
            let pinned = items.filter { pinnedIDs.contains($0.id) }
                .sorted { (usageCounts[$0.id] ?? 0) > (usageCounts[$1.id] ?? 0) }
            if !pinned.isEmpty {
                groups.append(ShortcutGroup(title: pinnedCategoryTitle, items: pinned))
                let pinnedSet = Set(pinned.map(\.id))
                remaining = items.filter { !pinnedSet.contains($0.id) }
            }
        }

        let orderedCats = computeOrderedCategories(from: remaining, pinnedIDs: [])
        let groupedDict = Dictionary(grouping: remaining, by: \.category)

        for cat in orderedCats {
            guard let catItems = groupedDict[cat], !catItems.isEmpty else { continue }
            groups.append(ShortcutGroup(title: cat, items: catItems))
        }

        return groups
    }

    public static func tokenizeQuery(_ query: String) -> [String] {
        query
            .lowercased()
            .replacingOccurrences(of: "+", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    public static func matchScore(
        item: ShortcutItem,
        tokens: [String],
        progress: ShortcutProgressData
    ) -> Int {
        let titleLower = item.title.lowercased()
        let subtitleLower = (item.subtitle ?? "").lowercased()
        let categoryLower = item.category.lowercased()
        let comboLower = item.keyCombo.displayString.lowercased()
        let keyLower = item.keyCombo.keyDisplay.lowercased()
        let modTokens = item.keyCombo.modifiers.searchTokens

        let keyAliases: [String] = {
            switch item.keyCombo.keyDisplay {
            case "↩": return ["return", "enter", "回车", "↩"]
            case "⇥": return ["tab", "⇥"]
            case "⌫": return ["delete", "backspace", "退格", "删除", "⌫"]
            case "⌦": return ["forwarddelete", "del", "⌦"]
            case "⎋": return ["esc", "escape", "退出", "⎋"]
            case "Space": return ["space", "空格"]
            case "↑": return ["up", "上", "↑"]
            case "↓": return ["down", "下", "↓"]
            case "←": return ["left", "左", "←"]
            case "→": return ["right", "右", "→"]
            default: return [keyLower]
            }
        }()

        var totalScore = 0
        for token in tokens {
            var tokenScore = 0
            if titleLower == token {
                tokenScore = max(tokenScore, 120)
            } else if titleLower.hasPrefix(token) {
                tokenScore = max(tokenScore, 95)
            } else if titleLower.contains(token) {
                tokenScore = max(tokenScore, 75)
            }

            if comboLower.contains(token) || keyAliases.contains(where: { $0.contains(token) }) {
                tokenScore = max(tokenScore, 80)
            }
            if modTokens.contains(where: { $0 == token || $0.hasPrefix(token) }) {
                tokenScore = max(tokenScore, 60)
            }
            if subtitleLower.contains(token) {
                tokenScore = max(tokenScore, 50)
            }
            if categoryLower.contains(token) {
                tokenScore = max(tokenScore, 45)
            }

            if tokenScore == 0 {
                return 0
            }
            totalScore += tokenScore
        }

        if progress.pinnedIDs.contains(item.id) { totalScore += 25 }
        if item.isEnabled { totalScore += 15 }
        if item.source == .contextTip { totalScore += 12 }
        if item.source == .liveMenu { totalScore += 8 }
        totalScore += min(progress.usageCounts[item.id] ?? 0, 10) * 2
        return totalScore
    }
}
