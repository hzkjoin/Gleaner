import Foundation
import Testing
@testable import GleanerCore

@Suite struct DueDateParserTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()
    /// Thursday 2026-11-05 10:30 in Shanghai.
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 10, minute: 30))! }

    private func parse(_ text: String) -> (String, Bool)? {
        guard let due = DueDateParser.parse(text, now: now, calendar: calendar) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = due.hasTime ? "MM-dd HH:mm" : "MM-dd"
        return (formatter.string(from: due.date), due.hasTime)
    }

    @Test func relativeDaysAndTimes() {
        #expect(parse("今天下午")! == ("11-05 15:00", true))
        #expect(parse("明天 15:00")! == ("11-06 15:00", true))
        #expect(parse("明天下午3点半")! == ("11-06 15:30", true))
        #expect(parse("后天上午十点")! == ("11-07 10:00", true))
        #expect(parse("今晚八点")! == ("11-05 20:00", true))
        #expect(parse("今天下班前")! == ("11-05 18:00", true))
        #expect(parse("中午12点")! == ("11-05 12:00", true))
        #expect(parse("明天")! == ("11-06", false))
    }

    @Test func weekdays() {
        #expect(parse("周五前")! == ("11-06", false))       // this Friday
        #expect(parse("周一")! == ("11-09", false))         // passed this week: next Monday
        #expect(parse("下周三下午2点")! == ("11-11 14:00", true))
        #expect(parse("星期日")! == ("11-08", false))
    }

    @Test func calendarDates() {
        #expect(parse("11月8日上午10点")! == ("11-08 10:00", true))
        #expect(parse("2026-11-20")! == ("11-20", false))
        #expect(parse("1月3日")! == ("01-03", false))        // next year
        #expect(parse("20号")! == ("11-20", false))
        #expect(parse("3号")! == ("12-03", false))           // passed this month: next month
    }

    @Test func unparseable() {
        #expect(parse("") == nil)
        #expect(parse("尽快") == nil)
        #expect(parse("本季度内") == nil)
    }
}
