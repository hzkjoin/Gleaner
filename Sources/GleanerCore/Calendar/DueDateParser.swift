import Foundation

/// Turns the due text the model writes ("今天下午", "明天 15:00", "周五前", "11月8日上午10点") into a date.
public enum DueDateParser {
    public struct Due: Equatable, Sendable {
        public var date: Date
        /// False when only the day is known (an all-day item).
        public var hasTime: Bool

        public init(date: Date, hasTime: Bool) {
            self.date = date
            self.hasTime = hasTime
        }
    }

    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Due? {
        let text = text.replacingOccurrences(of: "：", with: ":").replacingOccurrences(of: " ", with: "")
        guard !text.isEmpty else { return nil }
        let day = parseDay(text, now: now, calendar: calendar)
        let time = parseTime(text)
        guard day != nil || time != nil else { return nil }
        let base = calendar.startOfDay(for: day ?? now)
        guard let (hour, minute) = time else { return Due(date: base, hasTime: false) }
        let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? base
        return Due(date: date, hasTime: true)
    }

    // MARK: - Day

    static func parseDay(_ text: String, now: Date, calendar: Calendar) -> Date? {
        func offset(_ days: Int) -> Date? { calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) }
        if text.contains("大后天") { return offset(3) }
        if text.contains("后天") { return offset(2) }
        if text.contains("明天") || text.contains("明早") || text.contains("明晚") || text.contains("明日") { return offset(1) }
        if text.contains("今天") || text.contains("今晚") || text.contains("今早") || text.contains("今日") { return offset(0) }

        if let match = firstMatch(#"(\d{4})[-/年](\d{1,2})[-/月](\d{1,2})"#, in: text),
           let date = calendar.date(from: DateComponents(year: match[0], month: match[1], day: match[2])) {
            return date
        }
        if let match = firstMatch(#"(\d{1,2})[月/-](\d{1,2})[日号]?"#, in: text) {
            var components = calendar.dateComponents([.year], from: now)
            components.month = match[0]
            components.day = match[1]
            guard var date = calendar.date(from: components) else { return nil }
            // A date well in the past means next year ("1月3日" said in December).
            if date < calendar.date(byAdding: .month, value: -2, to: now)! {
                date = calendar.date(byAdding: .year, value: 1, to: date)!
            }
            return date
        }
        if let match = firstMatch(#"(下下|下)?(?:周|星期|礼拜)([一二三四五六日天1-7])"#, in: text, raw: true) {
            let weekday = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "日": 7, "天": 7,
                           "1": 1, "2": 2, "3": 3, "4": 4, "5": 5, "6": 6, "7": 7][match.groups[1]] ?? 1
            let weeksAhead = match.groups[0] == "下下" ? 2 : (match.groups[0] == "下" ? 1 : 0)
            // Calendar weekday: 1 = Sunday … 7 = Saturday → 1 = Monday … 7 = Sunday.
            let today = (calendar.component(.weekday, from: now) + 5) % 7 + 1
            var days = weekday - today + 7 * weeksAhead
            if weeksAhead == 0 && days < 0 { days += 7 }  // "周一" said on Wednesday means next Monday.
            return offset(days)
        }
        if let match = firstMatch(#"(?<![\d月])(\d{1,2})[日号]"#, in: text) {
            var components = calendar.dateComponents([.year, .month], from: now)
            components.day = match[0]
            guard var date = calendar.date(from: components) else { return nil }
            if date < calendar.startOfDay(for: now) { date = calendar.date(byAdding: .month, value: 1, to: date)! }
            return date
        }
        return nil
    }

    // MARK: - Time

    static func parseTime(_ text: String) -> (Int, Int)? {
        let pm = ["下午", "晚上", "晚", "傍晚", "今晚", "明晚"].contains { text.contains($0) }
        let noon = text.contains("中午")
        func adjust(_ hour: Int) -> Int {
            if pm && hour < 12 { return hour + 12 }
            if noon && hour < 5 { return hour + 12 }
            return hour
        }
        if let match = firstMatch(#"(\d{1,2}):(\d{2})"#, in: text), match[0] < 24, match[1] < 60 {
            return (adjust(match[0]), match[1])
        }
        if let match = firstMatch(#"([0-9一二两三四五六七八九十]{1,3})点(半|一刻|三刻|([0-9一二三四五六七八九十]{1,3})分?)?"#, in: text, raw: true),
           let hour = number(match.groups[0]), hour < 24 {
            let rest = match.groups[1]
            let minute = rest == "半" ? 30 : rest == "一刻" ? 15 : rest == "三刻" ? 45 : number(match.groups[2]) ?? 0
            return (adjust(hour), min(minute, 59))
        }
        if text.contains("下班前") || text.contains("下班") { return (18, 0) }
        if text.contains("上午") || text.contains("早上") || text.contains("明早") || text.contains("今早") { return (9, 0) }
        if noon { return (12, 0) }
        if text.contains("下午") { return (15, 0) }
        if pm { return (20, 0) }
        return nil
    }

    /// Arabic or simple Chinese numerals up to 99 ("十二", "两", "二十三").
    static func number(_ text: String) -> Int? {
        if let value = Int(text) { return value }
        let digits: [Character: Int] = ["零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        if let ten = text.firstIndex(of: "十") {
            let tens = text[..<ten].isEmpty ? 1 : digits[text[..<ten].first!] ?? 1
            let ones = text[text.index(after: ten)...].first.flatMap { digits[$0] } ?? 0
            return tens * 10 + ones
        }
        return text.count == 1 ? digits[text.first!] : nil
    }

    // MARK: - Regex

    private struct Match { var groups: [String] }

    private static func firstMatch(_ pattern: String, in text: String) -> [Int]? {
        firstMatch(pattern, in: text, raw: true).map { $0.groups.compactMap { Int($0) } }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func firstMatch(_ pattern: String, in text: String, raw: Bool) -> Match? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let groups = (1..<result.numberOfRanges).map { index -> String in
            guard let range = Range(result.range(at: index), in: text) else { return "" }
            return String(text[range])
        }
        return Match(groups: groups)
    }
}
