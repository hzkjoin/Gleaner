import Foundation

/// Kinds of news the curator files items under.
public enum NewsCategory: String, Codable, CaseIterable, Sendable {
    case trending, finance, tech, society, entertainment, sports, other

    public var displayName: String {
        switch self {
        case .trending: return "热搜"
        case .finance: return "财经"
        case .tech: return "科技"
        case .society: return "社会"
        case .entertainment: return "娱乐"
        case .sports: return "体育"
        case .other: return "其他"
        }
    }

    /// Accepts both the Chinese labels used in the prompt and the raw values.
    init(label: String) {
        let label = label.trimmingCharacters(in: .whitespaces)
        self = Self.allCases.first { $0.displayName == label || $0.rawValue == label.lowercased() } ?? .other
    }
}

/// A piece of news or a trending topic, condensed from one or more notifications, for browsing.
public struct NewsItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// One neutral sentence describing the event.
    public var headline: String
    public var category: NewsCategory
    public var appID: String
    public var origin: DeviceOrigin
    public var sourceTitle: String
    public var sourceExcerpt: String
    public var date: Date
    /// Ids of the notifications the item was condensed from. Used while processing; not stored.
    public var sourceIDs: [String] = []

    private enum CodingKeys: String, CodingKey {
        case id, headline, category, appID, origin, sourceTitle, sourceExcerpt, date
    }

    public init(
        id: UUID = UUID(),
        headline: String,
        category: NewsCategory = .other,
        appID: String,
        origin: DeviceOrigin = .mac,
        sourceTitle: String,
        sourceExcerpt: String,
        date: Date
    ) {
        self.id = id
        self.headline = headline
        self.category = category
        self.appID = appID
        self.origin = origin
        self.sourceTitle = sourceTitle
        self.sourceExcerpt = sourceExcerpt
        self.date = date
    }
}

extension Array where Element == NewsItem {
    /// Adds `new` items, drops repeated headlines, removes anything older than `maxAge`,
    /// and keeps at most `limit` items, newest first.
    public func merging(_ new: [NewsItem], now: Date = Date(), maxAge: TimeInterval = 86_400, limit: Int = 100) -> [NewsItem] {
        var seen = Set<String>()
        return (new + self)
            .sorted { $0.date > $1.date }
            .filter { now.timeIntervalSince($0.date) <= maxAge }
            .filter { seen.insert($0.headline.filter { !$0.isWhitespace && !$0.isPunctuation }).inserted }
            .prefix(limit)
            .map { $0 }
    }
}
