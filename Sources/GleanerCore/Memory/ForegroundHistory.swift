import Foundation

/// When each app was in front. Apps such as WeChat don't post notifications while the user is
/// looking at them, so those stretches are where the message record may have gaps.
///
/// Holds app identifiers and times only.
public struct ForegroundHistory: Codable, Equatable, Sendable {
    public struct Span: Codable, Equatable, Sendable {
        public var appID: String
        public var start: Date
        /// Nil while the app is still in front.
        public var end: Date?

        public init(appID: String, start: Date, end: Date? = nil) {
            self.appID = appID
            self.start = start
            self.end = end
        }
    }

    public private(set) var spans: [Span] = []
    /// How long spans are kept.
    public static let retention: TimeInterval = 7 * 24 * 3600
    static let maxSpans = 3000

    public init(spans: [Span] = []) {
        self.spans = spans
    }

    /// `appID` came to the front (nil: nothing tracked, e.g. the Mac went to sleep).
    public mutating func activate(_ appID: String?, at date: Date = Date()) {
        let id = appID?.lowercased()
        if let last = spans.last, last.end == nil {
            if last.appID == id { return }
            spans[spans.count - 1].end = date
        }
        if let id { spans.append(Span(appID: id, start: date)) }
        trim(now: date)
    }

    /// Stretches when `appID` was in front between `from` and `to`, merging ones a minute apart.
    public func gaps(for appID: String, from: Date, to: Date = Date()) -> [DateInterval] {
        let id = appID.lowercased()
        var result: [DateInterval] = []
        for span in spans where span.appID == id {
            let start = max(span.start, from)
            let end = min(span.end ?? to, to)
            guard end > start else { continue }
            if let last = result.last, start.timeIntervalSince(last.end) < 60 {
                result[result.count - 1] = DateInterval(start: last.start, end: max(last.end, end))
            } else {
                result.append(DateInterval(start: start, end: end))
            }
        }
        return result
    }

    /// A line for the model listing those stretches, or nil when there are none.
    public static func describe(_ gaps: [DateInterval], appName: String, limit: Int = 12) -> String? {
        guard !gaps.isEmpty else { return nil }
        let calendar = Calendar.current
        let times = gaps.suffix(limit).map { gap -> String in
            let day = calendar.isDateInToday(gap.start) ? "" : gap.start.formatted(.dateTime.month(.twoDigits).day(.twoDigits)) + " "
            let start = gap.start.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
            let end = gap.end.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
            return "\(day)\(start)–\(end)"
        }
        return "\(appName)：\(times.joined(separator: "、"))"
    }

    private mutating func trim(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        spans.removeAll { ($0.end ?? now) < cutoff }
        if spans.count > Self.maxSpans { spans.removeFirst(spans.count - Self.maxSpans) }
    }
}
