import AppKit
import GleanerCore
import SwiftUI

/// Today's next events, with a join button for video meetings.
struct EventsCard: View {
    let events: [CalendarEvent]
    let now: Date

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                if index > 0 {
                    Rectangle().fill(Theme.divider).frame(height: 0.5).padding(.leading, 12)
                }
                EventRow(event: event, now: now)
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.card)
            .shadow(color: .black.opacity(0.04), radius: 1.5, y: 1))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .strokeBorder(Theme.cardStroke, lineWidth: 0.5))
    }
}

private struct EventRow: View {
    @EnvironmentObject private var model: AppModel
    let event: CalendarEvent
    let now: Date

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title.isEmpty ? "日程" : event.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if !event.notes.isEmpty {
                    Text(event.notes)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                HStack(spacing: 5) {
                    if event.kind == .event && event.isOngoing(now: now) {
                        Circle().fill(Theme.positive).frame(width: 5, height: 5)
                        Text("进行中")
                    }
                    Text(meta).lineLimit(1)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(event.isOverdue(now: now) ? Theme.urgent : Theme.textSecondary)
            }
            Spacer(minLength: 8)
            if let meeting = event.meeting {
                Button("入会") { NSWorkspace.shared.open(meeting.url) }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .hoverHint(meeting.service)
            }
            if event.kind == .reminder {
                Button("完成") { model.completeReminder(event) }
                    .buttonStyle(PillButtonStyle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .clickable { AppDirectory.shared.open(event.kind == .reminder ? "com.apple.reminders" : "com.apple.iCal") }
    }

    private var meta: String {
        let time = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        if event.kind == .reminder {
            return (event.hasTime ? event.start.formatted(time) : "今天") + " 提醒事项"
        }
        var parts = ["\(event.start.formatted(time))–\(event.end.formatted(time))"]
        if let service = event.meeting?.service {
            parts.append(service)
        } else if !event.location.isEmpty {
            parts.append(event.location)
        }
        return parts.joined(separator: "  ")
    }
}
