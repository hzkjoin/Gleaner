import Foundation

/// Combines several sources, e.g. the Mac's own notifications and those forwarded from the iPhone.
///
/// - The same message can arrive through two sources (WeChat on Mac and iPhone; an SMS as
///   a notification and in the Messages database). Items from different sources with the same
///   body, from the same app or under the same title, within `duplicateWindow`, are kept
///   once, preferring the source listed first.
/// - A permission problem in any source is reported, so the user is asked to grant access.
///   Other failures are tolerated as long as at least one source works.
public struct CompositeNotificationSource: NotificationSource {
    public let sources: [NotificationSource]
    public let duplicateWindow: TimeInterval

    public init(_ sources: [NotificationSource], duplicateWindow: TimeInterval = 120) {
        self.sources = sources
        self.duplicateWindow = duplicateWindow
    }

    public func changeToken() -> Date? {
        sources.compactMap { $0.changeToken() }.max()
    }

    public func fetch(after date: Date) throws -> [AppNotification] {
        var batches: [[AppNotification]] = []
        var errors: [Error] = []
        for source in sources {
            do { batches.append(try source.fetch(after: date)) } catch { errors.append(error) }
        }
        if errors.contains(where: { ($0 as? NotificationSourceError) == .accessDenied }) {
            throw NotificationSourceError.accessDenied
        }
        if batches.isEmpty, let first = errors.first { throw first }

        var kept: [(source: Int, note: AppNotification)] = []
        var seenIDs = Set<String>()
        for (source, batch) in batches.enumerated() {
            for note in batch where seenIDs.insert(note.id).inserted {
                let duplicate = kept.contains { other in
                    other.source != source && !note.body.isEmpty && other.note.body == note.body
                        && (other.note.appID.lowercased() == note.appID.lowercased() || other.note.title == note.title)
                        && abs(other.note.date.timeIntervalSince(note.date)) <= duplicateWindow
                }
                if !duplicate { kept.append((source, note)) }
            }
        }
        return kept.map(\.note).sorted { $0.date < $1.date }
    }
}
