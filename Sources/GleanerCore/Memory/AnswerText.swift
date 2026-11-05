import Foundation

/// Splits answer text so sources can be shown quieter than the content.
public enum AnswerText {
    public struct Segment: Equatable, Sendable {
        public var text: String
        /// A short parenthetical naming where something came from: one with a time (e.g.
        /// "（微信，王总，11-05 07:51）"), or one that ends a sentence (e.g. "（东方财富）。").
        public var isSource: Bool

        public init(_ text: String, isSource: Bool = false) {
            self.text = text
            self.isSource = isSource
        }
    }

    // A parenthetical of up to 40 characters followed by punctuation or the end of the line.
    private static let source = try! NSRegularExpression(
        pattern: #"\s?[（(][^（）()\n]{1,40}[）)](?=\s*(?:[。，；、,.;！？!?]|$))"#)

    public static func segments(_ line: String) -> [Segment] {
        let text = line as NSString
        var segments: [Segment] = []
        var cursor = 0
        for match in source.matches(in: line, range: NSRange(location: 0, length: text.length)) where isSource(match.range, in: text) {
            if match.range.location > cursor {
                segments.append(Segment(text.substring(with: NSRange(location: cursor, length: match.range.location - cursor))))
            }
            segments.append(Segment(text.substring(with: match.range), isSource: true))
            cursor = match.range.location + match.range.length
        }
        if cursor < text.length { segments.append(Segment(text.substring(from: cursor))) }
        return segments
    }

    /// An aside mid-sentence ("口径（PE-TTM 是否剔除负值），结论…") is content, not a source.
    private static func isSource(_ range: NSRange, in text: NSString) -> Bool {
        let inner = text.substring(with: range)
        if inner.contains("·") || inner.range(of: #"\d{1,2}[:-]\d{2}"#, options: .regularExpression) != nil { return true }
        let rest = text.substring(from: range.location + range.length).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty || "。.！？!?".contains(rest.first!)
    }
}
