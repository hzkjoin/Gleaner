import Foundation

/// The active Focus (Do Not Disturb, Work, Sleep, ...), read from macOS's DoNotDisturb store.
public enum FocusStatus {
    public static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/DoNotDisturb/DB")

    /// The display name of the active Focus, or nil when none is on.
    public static func activeMode(directory: URL = defaultDirectory) -> String? {
        guard let assertions = try? Data(contentsOf: directory.appendingPathComponent("Assertions.json")),
              let configurations = try? Data(contentsOf: directory.appendingPathComponent("ModeConfigurations.json"))
        else { return nil }
        return activeMode(assertions: assertions, configurations: configurations)
    }

    static func activeMode(assertions: Data, configurations: Data) -> String? {
        guard let store = (json(assertions)?["data"] as? [[String: Any]])?.first else { return nil }
        let invalidated = Set((store["storeInvalidationRecords"] as? [[String: Any]] ?? []).compactMap {
            ($0["invalidationAssertion"] as? [String: Any])?["assertionUUID"] as? String
        })
        // Turning a Focus off leaves its assertion in place and adds an invalidation request
        // stamped at (or after) the assertion's start; such an assertion is no longer active.
        let lastRequest = (store["storeInvalidationRequestRecords"] as? [[String: Any]] ?? [])
            .compactMap { $0["invalidationRequestDateTimestamp"] as? Double }
            .max() ?? -.infinity
        let active = (store["storeAssertionRecords"] as? [[String: Any]] ?? []).first {
            if let uuid = $0["assertionUUID"] as? String, invalidated.contains(uuid) { return false }
            let start = $0["assertionStartDateTimestamp"] as? Double ?? .infinity
            return start > lastRequest
        }
        guard let modeID = (active?["assertionDetails"] as? [String: Any])?["assertionDetailsModeIdentifier"] as? String
        else { return nil }

        let modes = ((json(configurations)?["data"] as? [[String: Any]])?.first?["modeConfigurations"] as? [String: Any]) ?? [:]
        let name = ((modes[modeID] as? [String: Any])?["mode"] as? [String: Any])?["name"] as? String
        return localized(name ?? "专注模式")
    }

    private static func json(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Built-in modes store English names.
    private static func localized(_ name: String) -> String {
        ["Do Not Disturb": "勿扰模式", "Sleep": "睡眠", "Work": "工作", "Personal": "个人", "Driving": "驾驶",
         "Fitness": "健身", "Reading": "阅读", "Gaming": "游戏", "Mindfulness": "正念"][name] ?? name
    }
}
