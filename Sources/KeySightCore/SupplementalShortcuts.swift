import Foundation

public enum SupplementalShortcuts {
    /// Returns context-aware & app-specific & system-global shortcuts that don't always appear in macOS menu bars.
    public static func shortcuts(for bundleID: String, focusContext: FocusContextKind) -> [ShortcutItem] {
        var items: [ShortcutItem] = []

        // 1. Focus-context highest-priority tips ("当前界面推荐")
        items.append(contentsOf: contextTips(for: focusContext, bundleID: bundleID))

        // 2. App-specific non-menu shortcuts
        items.append(contentsOf: appSpecificShortcuts(for: bundleID))

        // 3. System-wide anti-trackpad shortcuts
        items.append(contentsOf: systemGlobalShortcuts())

        return items
    }

    private static func make(
        scope: String,
        title: String,
        subtitle: String? = nil,
        category: String,
        mods: KeyModifiers,
        key: String,
        source: ShortcutSource,
        priority: Int = 50
    ) -> ShortcutItem {
        let combo = KeyCombo(
            modifiers: mods,
            keyDisplay: key,
            virtualKeyCode: KeyFormatting.keyDisplayToVirtualKey(key)
        )
        return ShortcutItem(
            id: "\(scope)::\(category)::\(title)::\(combo.normalizedSignature)",
            appBundleID: scope,
            title: title,
            subtitle: subtitle,
            category: category,
            keyCombo: combo,
            isEnabled: true,
            source: source,
            menuPath: [],
            priority: priority
        )
    }

    private static func contextTips(for context: FocusContextKind, bundleID: String) -> [ShortcutItem] {
        switch context {
        case .textInput:
            let cat = "光标与编辑（免触控板）"
            return [
                make(scope: "ctx.text", title: "跳到行首", subtitle: "Emacs 风格，无需离开主键区", category: cat, mods: [.control], key: "A", source: .contextTip, priority: 95),
                make(scope: "ctx.text", title: "跳到行尾", subtitle: "全 macOS 输入框通用", category: cat, mods: [.control], key: "E", source: .contextTip, priority: 94),
                make(scope: "ctx.text", title: "按词向左移动", subtitle: "加 ⇧ 可同时选中", category: cat, mods: [.option], key: "←", source: .contextTip, priority: 92),
                make(scope: "ctx.text", title: "按词向右移动", subtitle: "加 ⇧ 可同时选中", category: cat, mods: [.option], key: "→", source: .contextTip, priority: 91),
                make(scope: "ctx.text", title: "删除前一个词", subtitle: "比连按退格快得多", category: cat, mods: [.option], key: "⌫", source: .contextTip, priority: 90),
                make(scope: "ctx.text", title: "删除到行首", subtitle: "清空当前行左侧", category: cat, mods: [.command], key: "⌫", source: .contextTip, priority: 89),
                make(scope: "ctx.text", title: "删除到行尾", subtitle: "剪掉光标右侧整行", category: cat, mods: [.control], key: "K", source: .contextTip, priority: 88),
                make(scope: "ctx.text", title: "跳到文首 / 顶部", category: cat, mods: [.command], key: "↑", source: .contextTip, priority: 85),
                make(scope: "ctx.text", title: "跳到文末 / 底部", category: cat, mods: [.command], key: "↓", source: .contextTip, priority: 84),
                make(scope: "ctx.text", title: "向后删除字符", subtitle: "等效 Windows Delete", category: cat, mods: [.control], key: "D", source: .contextTip, priority: 82)
            ]

        case .browserWeb:
            let cat = "网页浏览（免触控板）"
            return [
                make(scope: "ctx.web", title: "向下翻一屏", subtitle: "告别触控板双指滚动", category: cat, mods: [], key: "Space", source: .contextTip, priority: 96),
                make(scope: "ctx.web", title: "向上翻一屏", subtitle: "反向翻页", category: cat, mods: [.shift], key: "Space", source: .contextTip, priority: 95),
                make(scope: "ctx.web", title: "聚焦地址栏", subtitle: "直接输网址或搜索", category: cat, mods: [.command], key: "L", source: .contextTip, priority: 94),
                make(scope: "ctx.web", title: "切换下一个标签页", category: cat, mods: [.control], key: "⇥", source: .contextTip, priority: 93),
                make(scope: "ctx.web", title: "切换上一个标签页", category: cat, mods: [.control, .shift], key: "⇥", source: .contextTip, priority: 92),
                make(scope: "ctx.web", title: "后退上一页", category: cat, mods: [.command], key: "[", source: .contextTip, priority: 90),
                make(scope: "ctx.web", title: "前进下一页", category: cat, mods: [.command], key: "]", source: .contextTip, priority: 89),
                make(scope: "ctx.web", title: "恢复刚关闭的标签页", category: cat, mods: [.command, .shift], key: "T", source: .contextTip, priority: 88)
            ]

        case .listOrTable:
            let cat = "列表导航（免触控板）"
            var items = [
                make(scope: "ctx.list", title: "跳到列表顶部", category: cat, mods: [.option], key: "↑", source: .contextTip, priority: 90),
                make(scope: "ctx.list", title: "跳到列表底部", category: cat, mods: [.option], key: "↓", source: .contextTip, priority: 89),
                make(scope: "ctx.list", title: "快速预览选中项", subtitle: "Quick Look / 展开预览", category: cat, mods: [], key: "Space", source: .contextTip, priority: 88)
            ]
            if bundleID == "com.apple.finder" {
                items.insert(
                    make(scope: "ctx.list", title: "重命名选中文件", subtitle: "不用双击文件名", category: cat, mods: [], key: "↩", source: .contextTip, priority: 95),
                    at: 0
                )
            }
            return items

        case .general:
            return []
        }
    }

    private static func appSpecificShortcuts(for bundleID: String) -> [ShortcutItem] {
        let lower = bundleID.lowercased()

        // Browsers
        let browserIDs = [
            "com.apple.safari", "com.google.chrome", "company.thebrowser.browser",
            "com.microsoft.edgemac", "org.mozilla.firefox", "com.brave.browser",
            "com.operasoftware.opera", "com.vivaldi.vivaldi", "company.thebrowser.dia",
            "ai.perplexity.comet"
        ]
        if browserIDs.contains(where: { lower.contains($0) }) {
            let cat = "浏览器高频"
            return [
                make(scope: "app.browser", title: "向下翻页", subtitle: "替代触控板滚动", category: cat, mods: [], key: "Space", source: .appSupplemental, priority: 80),
                make(scope: "app.browser", title: "向上翻页", category: cat, mods: [.shift], key: "Space", source: .appSupplemental, priority: 79),
                make(scope: "app.browser", title: "聚焦地址栏", category: cat, mods: [.command], key: "L", source: .appSupplemental, priority: 78),
                make(scope: "app.browser", title: "下一个标签页", category: cat, mods: [.control], key: "⇥", source: .appSupplemental, priority: 77),
                make(scope: "app.browser", title: "上一个标签页", category: cat, mods: [.control, .shift], key: "⇥", source: .appSupplemental, priority: 76),
                make(scope: "app.browser", title: "直达第 1~8 个标签页", subtitle: "⌘9 跳到最后一个标签", category: cat, mods: [.command], key: "1", source: .appSupplemental, priority: 74),
                make(scope: "app.browser", title: "恢复已关闭标签页", category: cat, mods: [.command, .shift], key: "T", source: .appSupplemental, priority: 73),
                make(scope: "app.browser", title: "网页后退", category: cat, mods: [.command], key: "[", source: .appSupplemental, priority: 72),
                make(scope: "app.browser", title: "网页前进", category: cat, mods: [.command], key: "]", source: .appSupplemental, priority: 71),
                make(scope: "app.browser", title: "下一个查找结果", subtitle: "⌘F 查找后连续跳转", category: cat, mods: [.command], key: "G", source: .appSupplemental, priority: 70)
            ]
        }

        // Finder
        if lower == "com.apple.finder" {
            let cat = "访达高频"
            return [
                make(scope: "app.finder", title: "快速预览文件", subtitle: "空格键开关 Quick Look", category: cat, mods: [], key: "Space", source: .appSupplemental, priority: 85),
                make(scope: "app.finder", title: "重命名选中项", category: cat, mods: [], key: "↩", source: .appSupplemental, priority: 84),
                make(scope: "app.finder", title: "打开选中文件夹/文件", category: cat, mods: [.command], key: "↓", source: .appSupplemental, priority: 83),
                make(scope: "app.finder", title: "返回上一级目录", category: cat, mods: [.command], key: "↑", source: .appSupplemental, priority: 82),
                make(scope: "app.finder", title: "前往指定路径", subtitle: "直接输入 ~/Desktop 等路径", category: cat, mods: [.command, .shift], key: "G", source: .appSupplemental, priority: 81),
                make(scope: "app.finder", title: "显示 / 隐藏隐藏文件", category: cat, mods: [.command, .shift], key: ".", source: .appSupplemental, priority: 80),
                make(scope: "app.finder", title: "移到废纸篓", category: cat, mods: [.command], key: "⌫", source: .appSupplemental, priority: 79),
                make(scope: "app.finder", title: "剪切并粘贴移动文件", subtitle: "先 ⌘C 复制，再 ⌘⌥V 移动", category: cat, mods: [.command, .option], key: "V", source: .appSupplemental, priority: 78)
            ]
        }

        // Terminals
        let terminalIDs = ["com.apple.terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.warp-stable", "net.kovidgoyal.kitty", "org.alacritty"]
        if terminalIDs.contains(where: { lower.contains($0) }) {
            let cat = "终端命令行高频"
            return [
                make(scope: "app.terminal", title: "反向搜索历史命令", subtitle: "输入关键词秒找旧命令", category: cat, mods: [.control], key: "R", source: .appSupplemental, priority: 86),
                make(scope: "app.terminal", title: "清屏", category: cat, mods: [.control], key: "L", source: .appSupplemental, priority: 85),
                make(scope: "app.terminal", title: "跳到命令行首", category: cat, mods: [.control], key: "A", source: .appSupplemental, priority: 84),
                make(scope: "app.terminal", title: "跳到命令行尾", category: cat, mods: [.control], key: "E", source: .appSupplemental, priority: 83),
                make(scope: "app.terminal", title: "删除前一个词", category: cat, mods: [.control], key: "W", source: .appSupplemental, priority: 82),
                make(scope: "app.terminal", title: "清空光标前整行", category: cat, mods: [.control], key: "U", source: .appSupplemental, priority: 81),
                make(scope: "app.terminal", title: "终止当前进程", category: cat, mods: [.control], key: "C", source: .appSupplemental, priority: 80)
            ]
        }

        // VS Code / Cursor / Windsurf / Antigravity
        let vscodeIDs = ["com.microsoft.vscode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "com.google.antigravity"]
        if vscodeIDs.contains(where: { lower.contains($0) }) {
            let cat = "编辑器高频"
            return [
                make(scope: "app.vscode", title: "快速打开文件", subtitle: "免点文件树", category: cat, mods: [.command], key: "P", source: .appSupplemental, priority: 86),
                make(scope: "app.vscode", title: "命令面板", subtitle: "键盘执行任意功能", category: cat, mods: [.command, .shift], key: "P", source: .appSupplemental, priority: 85),
                make(scope: "app.vscode", title: "显示 / 隐藏侧边栏", category: cat, mods: [.command], key: "B", source: .appSupplemental, priority: 84),
                make(scope: "app.vscode", title: "显示 / 隐藏内置终端", category: cat, mods: [.control], key: "`", source: .appSupplemental, priority: 83),
                make(scope: "app.vscode", title: "选中下一个相同词", subtitle: "多光标批量修改", category: cat, mods: [.command], key: "D", source: .appSupplemental, priority: 82),
                make(scope: "app.vscode", title: "向上移动当前行", category: cat, mods: [.option], key: "↑", source: .appSupplemental, priority: 81),
                make(scope: "app.vscode", title: "向下移动当前行", category: cat, mods: [.option], key: "↓", source: .appSupplemental, priority: 80),
                make(scope: "app.vscode", title: "注释 / 取消注释", category: cat, mods: [.command], key: "/", source: .appSupplemental, priority: 79),
                make(scope: "app.vscode", title: "拆分编辑器窗口", category: cat, mods: [.command], key: "\\", source: .appSupplemental, priority: 78)
            ]
        }

        // Preview / PDF
        if lower == "com.apple.preview" {
            let cat = "预览高频"
            return [
                make(scope: "app.preview", title: "下一页", category: cat, mods: [.option], key: "↓", source: .appSupplemental, priority: 80),
                make(scope: "app.preview", title: "上一页", category: cat, mods: [.option], key: "↑", source: .appSupplemental, priority: 79),
                make(scope: "app.preview", title: "适合窗口大小", category: cat, mods: [.command], key: "9", source: .appSupplemental, priority: 78),
                make(scope: "app.preview", title: "实际大小", category: cat, mods: [.command], key: "0", source: .appSupplemental, priority: 77)
            ]
        }

        return []
    }

    private static func systemGlobalShortcuts() -> [ShortcutItem] {
        let cat = "系统与窗口（全局）"
        return [
            make(scope: "sys.global", title: "切换应用程序", subtitle: "按住 ⌘ 时按 Q 退出 / H 隐藏", category: cat, mods: [.command], key: "⇥", source: .systemGlobal, priority: 45),
            make(scope: "sys.global", title: "同应用窗口间切换", subtitle: "不用触控板找窗口", category: cat, mods: [.command], key: "`", source: .systemGlobal, priority: 44),
            make(scope: "sys.global", title: "调度中心 (Mission Control)", category: cat, mods: [.control], key: "↑", source: .systemGlobal, priority: 42),
            make(scope: "sys.global", title: "切换左侧桌面空间", category: cat, mods: [.control], key: "←", source: .systemGlobal, priority: 41),
            make(scope: "sys.global", title: "切换右侧桌面空间", category: cat, mods: [.control], key: "→", source: .systemGlobal, priority: 40),
            make(scope: "sys.global", title: "切换全屏模式", category: cat, mods: [.control, .command], key: "F", source: .systemGlobal, priority: 39),
            make(scope: "sys.global", title: "隐藏当前应用", category: cat, mods: [.command], key: "H", source: .systemGlobal, priority: 38),
            make(scope: "sys.global", title: "打开当前应用设置", category: cat, mods: [.command], key: ",", source: .systemGlobal, priority: 37),
            make(scope: "sys.global", title: "区域截图", subtitle: "⌘⇧5 打开录屏与截图工具栏", category: cat, mods: [.command, .shift], key: "4", source: .systemGlobal, priority: 36),
            make(scope: "sys.global", title: "键盘聚焦顶部菜单栏", subtitle: "无需鼠标点菜单", category: cat, mods: [.control], key: "F2", source: .systemGlobal, priority: 35),
            make(scope: "sys.global", title: "键盘聚焦程序坞 Dock", category: cat, mods: [.control], key: "F3", source: .systemGlobal, priority: 34)
        ]
    }
}
