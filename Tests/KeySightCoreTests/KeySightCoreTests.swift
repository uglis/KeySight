import Foundation
import KeySightCore

@main
struct KeySightCoreTestRunner {
    static var passed = 0
    static var failed = 0

    static func check(_ condition: Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
        if condition {
            passed += 1
        } else {
            failed += 1
            fputs("FAIL [\(file):\(line)]: \(message)\n", stderr)
        }
    }

    static func main() {
        testAXModifierDecoding()
        testBuildKeyComboFromAXAttributes()
        testMergeDeduplicatesLiveMenuOverSupplemental()
        testEnabledFilterAndMasteredPinBehavior()
        testSearchMatchesChineseEnglishAndKeyTokens()
        testProgressStorePersistence()
        testAppearanceStyles()
        testHideBasicShortcutsAndLiveModifierFilter()
        testOverlayPagination()

        print("KeySightCoreTests finished: \(passed) passed, \(failed) failed")
        if failed > 0 {
            exit(1)
        }
    }

    static func testAXModifierDecoding() {
        check(KeyFormatting.decodeAXModifiers(0) == [.command], "0 -> Command")
        check(KeyFormatting.decodeAXModifiers(nil) == [.command], "nil -> Command")
        check(KeyFormatting.decodeAXModifiers(1) == [.shift, .command], "1 -> Shift+Command")
        check(KeyFormatting.decodeAXModifiers(2) == [.option, .command], "2 -> Option+Command")
        check(KeyFormatting.decodeAXModifiers(4) == [.control, .command], "4 -> Control+Command")
        check(KeyFormatting.decodeAXModifiers(8) == [], "8 -> No Command")
        check(KeyFormatting.decodeAXModifiers(12) == [.control], "12 -> Control only")
        check(KeyFormatting.decodeAXModifiers(7) == [.control, .option, .shift, .command], "7 -> all modifiers")
        check(KeyFormatting.decodeAXModifiers(7).symbols == ["⌃", "⌥", "⇧", "⌘"], "canonical macOS modifier order")
    }

    static func testBuildKeyComboFromAXAttributes() {
        let newFolder = KeyFormatting.buildKeyCombo(cmdChar: "N", virtualKey: nil, glyph: nil, modifiersRaw: 1)
        check(newFolder?.displayString == "⇧⌘N", "⇧⌘N formatting")
        check(newFolder?.keycaps == ["⇧", "⌘", "N"], "keycaps split")

        let nextTab = KeyFormatting.buildKeyCombo(cmdChar: nil, virtualKey: nil, glyph: 2, modifiersRaw: 12)
        check(nextTab?.displayString == "⌃⇥", "glyph 2 -> ⇥ with Control only")

        let upDir = KeyFormatting.buildKeyCombo(cmdChar: nil, virtualKey: 0x7E, glyph: nil, modifiersRaw: 0)
        check(upDir?.displayString == "⌘↑", "virtualKey 0x7E -> ↑")

        let trash = KeyFormatting.buildKeyCombo(cmdChar: nil, virtualKey: nil, glyph: 23, modifiersRaw: 0)
        check(trash?.displayString == "⌘⌫", "glyph 23 -> ⌫")
    }

    static func testMergeDeduplicatesLiveMenuOverSupplemental() {
        let liveFind = ShortcutItem(
            appBundleID: "com.apple.Safari",
            title: "打开位置…",
            category: "文件",
            keyCombo: KeyCombo(modifiers: [.command], keyDisplay: "L"),
            isEnabled: true,
            source: .liveMenu,
            menuPath: ["文件", "打开位置…"]
        )
        let snapshot = AppScanSnapshot(
            pid: 100,
            bundleID: "com.apple.Safari",
            appName: "Safari",
            focusContext: .browserWeb,
            liveMenuShortcuts: [liveFind]
        )

        let merged = ShortcutSearchEngine.mergeShortcuts(snapshot: snapshot, includeSupplemental: true)
        let cmdLMatches = merged.filter { $0.keyCombo.normalizedSignature == liveFind.keyCombo.normalizedSignature }
        check(cmdLMatches.count == 1, "dedup ⌘L to single item")
        check(cmdLMatches.first?.source == .liveMenu, "live menu takes priority over supplemental")
        check(cmdLMatches.first?.title == "打开位置…", "preserves live menu title")
    }

    static func testEnabledFilterAndMasteredPinBehavior() {
        let enabledItem = ShortcutItem(
            id: "app::copy",
            appBundleID: "com.test.app",
            title: "拷贝",
            category: "编辑",
            keyCombo: KeyCombo(modifiers: [.command], keyDisplay: "C"),
            isEnabled: true,
            source: .liveMenu
        )
        let disabledItem = ShortcutItem(
            id: "app::paste",
            appBundleID: "com.test.app",
            title: "粘贴",
            category: "编辑",
            keyCombo: KeyCombo(modifiers: [.command], keyDisplay: "V"),
            isEnabled: false,
            source: .liveMenu
        )
        let pinnedItem = ShortcutItem(
            id: "app::find",
            appBundleID: "com.test.app",
            title: "查找",
            category: "编辑",
            keyCombo: KeyCombo(modifiers: [.command], keyDisplay: "F"),
            isEnabled: true,
            source: .liveMenu
        )

        let snapshot = AppScanSnapshot(
            pid: 42,
            bundleID: "com.test.app",
            appName: "TestApp",
            focusContext: .general,
            liveMenuShortcuts: [enabledItem, disabledItem, pinnedItem]
        )

        let progress = ShortcutProgressData(
            pinnedIDs: ["app::find"],
            masteredIDs: ["app::copy"]
        )

        let result = ShortcutSearchEngine.buildViewResult(
            snapshot: snapshot,
            progress: progress,
            options: ShortcutFilterOptions(onlyEnabled: true, includeSupplemental: false, hideMastered: true, hideBasicShortcuts: false)
        )

        check(result.totalAvailableCount == 2, "filters out disabled menu items")
        check(result.totalMasteredCount == 1, "tracks mastered item count")
        check(result.masteredItems.map(\.id) == ["app::copy"], "mastered drawer contains mastered item")
        check(result.groups.first?.title == ShortcutSearchEngine.pinnedCategoryTitle, "pinned group surfaces first")
        check(result.groups.first?.items.map(\.id) == ["app::find"], "pinned item in pinned group")
    }

    static func testSearchMatchesChineseEnglishAndKeyTokens() {
        let item1 = ShortcutItem(
            appBundleID: "com.test.app",
            title: "新建标签页",
            category: "文件",
            keyCombo: KeyCombo(modifiers: [.command], keyDisplay: "T"),
            isEnabled: true,
            source: .liveMenu
        )
        let item2 = ShortcutItem(
            appBundleID: "com.test.app",
            title: "重新打开关闭的标签页",
            category: "历史记录",
            keyCombo: KeyCombo(modifiers: [.command, .shift], keyDisplay: "T"),
            isEnabled: true,
            source: .liveMenu
        )
        let snapshot = AppScanSnapshot(
            pid: 1,
            bundleID: "com.test.app",
            appName: "Browser",
            liveMenuShortcuts: [item1, item2]
        )

        let byKeyword = ShortcutSearchEngine.buildViewResult(
            snapshot: snapshot,
            progress: ShortcutProgressData(),
            options: ShortcutFilterOptions(query: "cmd shift t", includeSupplemental: false)
        )
        check(byKeyword.flatVisibleItems.count == 1, "cmd shift t matches exact shortcut")
        check(byKeyword.flatVisibleItems.first?.title == "重新打开关闭的标签页", "matched title is correct")

        let byChinese = ShortcutSearchEngine.buildViewResult(
            snapshot: snapshot,
            progress: ShortcutProgressData(),
            options: ShortcutFilterOptions(query: "标签", includeSupplemental: false)
        )
        check(byChinese.flatVisibleItems.count == 2, "Chinese token matches both tab items")
    }

    static func testProgressStorePersistence() {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = tmpDir.appendingPathComponent("progress.json")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = ShortcutProgressStore(fileURL: fileURL)
        check(store.togglePinned("k1") == true, "pin k1")
        check(store.toggleMastered("k2") == true, "master k2")
        store.recordUsage("k1")

        check(store.togglePinned("k2") == true, "pin k2")
        check(store.isMastered("k2") == false, "pinning un-masters k2")

        let reloaded = ShortcutProgressStore(fileURL: fileURL)
        check(reloaded.isPinned("k1") == true, "persisted k1 pin")
        check(reloaded.isPinned("k2") == true, "persisted k2 pin")
        check(reloaded.usageCount(for: "k1") == 1, "persisted usage count")
    }

    static func testAppearanceStyles() {
        check(HUDAppearanceStyle.liquidGlassClear.isLiquidGlass == true, "liquidGlassClear is liquid glass")
        check(HUDAppearanceStyle.liquidGlass.isLiquidGlass == true, "liquidGlass is liquid glass")
        check(HUDAppearanceStyle.frostedHUD.isLiquidGlass == false, "frostedHUD is classic frosted")
        check(HUDAppearanceStyle.solidGraphite.isLiquidGlass == false, "solidGraphite is solid")
        check(HUDAppearanceStyle.liquidGlassClear.next == .liquidGlass, "cycles to next style")
        check(HUDAppearanceStyle.solidGraphite.next == .liquidGlassClear, "wraps around to liquidGlassClear")
    }

    static func testHideBasicShortcutsAndLiveModifierFilter() {
        let copy = ShortcutItem(
            id: "b::copy", appBundleID: "com.test", title: "拷贝", category: "编辑",
            keyCombo: KeyCombo(modifiers: [.command], keyDisplay: "C"), source: .liveMenu
        )
        let save = ShortcutItem(
            id: "b::save", appBundleID: "com.test", title: "存储", category: "文件",
            keyCombo: KeyCombo(modifiers: [.command], keyDisplay: "S"), source: .liveMenu
        )
        let cmdShiftT = ShortcutItem(
            id: "b::reopen", appBundleID: "com.test", title: "恢复标签页", category: "历史",
            keyCombo: KeyCombo(modifiers: [.command, .shift], keyDisplay: "T"), source: .liveMenu
        )
        let cmdOptI = ShortcutItem(
            id: "b::devtools", appBundleID: "com.test", title: "检查元素", category: "开发",
            keyCombo: KeyCombo(modifiers: [.command, .option], keyDisplay: "I"), source: .liveMenu
        )

        let snapshot = AppScanSnapshot(
            pid: 7, bundleID: "com.test", appName: "Demo",
            liveMenuShortcuts: [copy, save, cmdShiftT, cmdOptI]
        )

        // Hide universal basics (⌘C, ⌘S)
        let hidden = ShortcutSearchEngine.buildViewResult(
            snapshot: snapshot,
            progress: ShortcutProgressData(),
            options: ShortcutFilterOptions(includeSupplemental: false, hideBasicShortcuts: true)
        )
        check(hidden.hiddenBasicCount == 2, "counts 2 hidden universal basic shortcuts")
        check(hidden.flatVisibleItems.count == 2, "keeps non-basic shortcuts visible")

        // Live Which-Key modifier filter: holding ⌘ + ⇧
        let shiftFiltered = ShortcutSearchEngine.buildViewResult(
            snapshot: snapshot,
            progress: ShortcutProgressData(),
            options: ShortcutFilterOptions(
                includeSupplemental: false,
                hideBasicShortcuts: true,
                requiredModifiers: [.command, .shift]
            )
        )
        check(shiftFiltered.flatVisibleItems.map(\.id) == ["b::reopen"], "live ⌘⇧ filter narrows to exact chord")
    }

    static func testOverlayPagination() {
        // 30 items in a single category should split across multiple columns & pages without losing items
        let items = (1...30).map { i in
            ShortcutItem(
                id: "p::\(i)", appBundleID: "com.test", title: "操作 \(i)", category: "编辑",
                keyCombo: KeyCombo(modifiers: [.command], keyDisplay: "\(i)"), source: .liveMenu
            )
        }
        let groups = [ShortcutGroup(title: "编辑", items: items)]
        let pages = ShortcutSearchEngine.paginateGroupsForOverlay(groups, columnsPerPage: 2, maxUnitsPerColumn: 10)
        check(pages.count >= 2, "splits 30 items into multiple zero-scroll pages")

        let allPackedIDs = pages.flatMap { $0.columns.flatMap { $0.groups.flatMap { $0.items.map(\.id) } } }
        check(allPackedIDs.count == 30, "preserves all 30 items across pages")
        check(pages[0].columns[1].groups.first?.title == "编辑（续）", "labels continuation columns cleanly")
    }
}
