import Foundation

public struct ShortcutProgressData: Codable, Sendable {
    public var pinnedIDs: Set<String>
    public var masteredIDs: Set<String>
    public var usageCounts: [String: Int]

    public init(
        pinnedIDs: Set<String> = [],
        masteredIDs: Set<String> = [],
        usageCounts: [String: Int] = [:]
    ) {
        self.pinnedIDs = pinnedIDs
        self.masteredIDs = masteredIDs
        self.usageCounts = usageCounts
    }
}

public final class ShortcutProgressStore {
    public private(set) var data: ShortcutProgressData
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let customURL = fileURL {
            self.fileURL = customURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.fileURL = appSupport
                .appendingPathComponent("KeySight", isDirectory: true)
                .appendingPathComponent("progress.json")
        }
        self.data = Self.load(from: self.fileURL)
    }

    public func isPinned(_ id: String) -> Bool {
        data.pinnedIDs.contains(id)
    }

    public func isMastered(_ id: String) -> Bool {
        data.masteredIDs.contains(id)
    }

    public func usageCount(for id: String) -> Int {
        data.usageCounts[id] ?? 0
    }

    @discardableResult
    public func togglePinned(_ id: String) -> Bool {
        let nowPinned: Bool
        if data.pinnedIDs.contains(id) {
            data.pinnedIDs.remove(id)
            nowPinned = false
        } else {
            data.pinnedIDs.insert(id)
            // Pinning an item means you want to practice it, so un-master it automatically
            data.masteredIDs.remove(id)
            nowPinned = true
        }
        save()
        return nowPinned
    }

    @discardableResult
    public func toggleMastered(_ id: String) -> Bool {
        let nowMastered: Bool
        if data.masteredIDs.contains(id) {
            data.masteredIDs.remove(id)
            nowMastered = false
        } else {
            data.masteredIDs.insert(id)
            // Mastered items leave the active practice pin list
            data.pinnedIDs.remove(id)
            nowMastered = true
        }
        save()
        return nowMastered
    }

    public func recordUsage(_ id: String) {
        data.usageCounts[id, default: 0] += 1
        save()
    }

    public func resetMastered(for ids: [String]) {
        for id in ids {
            data.masteredIDs.remove(id)
        }
        save()
    }

    private static func load(from url: URL) -> ShortcutProgressData {
        guard let raw = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(ShortcutProgressData.self, from: raw) else {
            return ShortcutProgressData()
        }
        return decoded
    }

    private func save() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let encoded = try? encoder.encode(data) {
            try? encoded.write(to: fileURL, options: .atomic)
        }
    }
}
