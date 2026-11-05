import Foundation

/// A long file's text cut into numbered sections, so the model can be given the start and an
/// outline, and read further sections when the question needs them.
public struct DocumentSections: Equatable, Sendable {
    /// Characters per section, about.
    public static let size = 8_000
    /// Outline lines shown at most; later sections can still be read.
    static let outlineLimit = 150

    public let sections: [String]

    public init(text: String, size: Int = DocumentSections.size) {
        var sections: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = Substring(line)
            // A single line longer than a section is cut where it must be.
            while line.count > size {
                if !current.isEmpty { sections.append(current); current = "" }
                sections.append(String(line.prefix(size)))
                line = line.dropFirst(size)
            }
            // Past half a section, start a new one at a heading so the outline names it.
            let breakAtHeading = current.count > size / 2 && Self.isHeading(line.trimmingCharacters(in: .whitespaces))
            if (current.count + line.count + 1 > size || breakAtHeading), !current.isEmpty {
                sections.append(current)
                current = ""
            }
            current += current.isEmpty ? String(line) : "\n" + line
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sections.append(current) }
        self.sections = sections
    }

    public var count: Int { sections.count }

    /// Section `number`, counting from 1.
    public func section(_ number: Int) -> String? {
        sections.indices.contains(number - 1) ? sections[number - 1] : nil
    }

    /// A line per section: a heading near its start if there is one, else its first words.
    public var outline: String {
        let lines = sections.prefix(Self.outlineLimit).enumerated().map { index, text in
            "\(index + 1). \(Self.label(of: text))"
        }
        let more = sections.count > Self.outlineLimit ? "\n（后面还有 \(sections.count - Self.outlineLimit) 段）" : ""
        return lines.joined(separator: "\n") + more
    }

    /// Short lines without closing punctuation read as headings.
    static func isHeading(_ line: String) -> Bool {
        let ending: Set<Character> = ["。", "，", "；", ".", ",", ";", "：", ":", "、"]
        return (2...30).contains(line.count) && !ending.contains(line.last ?? " ")
    }

    /// One line that matched a search, numbered across the whole file.
    public struct Match: Equatable, Sendable {
        public var section: Int
        public var line: Int
        public var text: String
    }

    /// Lines containing any of `keywords` (case ignored), in order, each with the line before
    /// and after when `context` is 1. Returns at most `limit` matching lines and the total count.
    public func search(_ keywords: [String], context: Int = 1, limit: Int = 30) -> (lines: [Match], total: Int) {
        let keywords = keywords.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        guard !keywords.isEmpty else { return ([], 0) }
        var all: [Match] = []
        for (index, section) in sections.enumerated() {
            for line in section.split(separator: "\n", omittingEmptySubsequences: false) {
                all.append(Match(section: index + 1, line: all.count + 1, text: String(line)))
            }
        }
        let hits = all.indices.filter { index in
            let line = all[index].text.lowercased()
            return keywords.contains { line.contains($0) }
        }
        var shown: [Int] = []
        for hit in hits.prefix(limit) {
            for index in max(0, hit - context)...min(all.count - 1, hit + context)
            where shown.last.map({ index > $0 }) ?? true {
                if !all[index].text.trimmingCharacters(in: .whitespaces).isEmpty || index == hit { shown.append(index) }
            }
        }
        let lines = shown.map { index -> Match in
            var match = all[index]
            match.text = Self.excerpt(match.text, around: keywords)
            return match
        }
        return (lines, hits.count)
    }

    /// A long line cut to about 200 characters around the first keyword in it.
    static func excerpt(_ line: String, around keywords: [String], width: Int = 200) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > width else { return trimmed }
        let lower = trimmed.lowercased()
        let hit = keywords.compactMap { lower.range(of: $0) }.first
        let center = hit.map { lower.distance(from: lower.startIndex, to: $0.lowerBound) } ?? 0
        let start = max(0, min(center - width / 3, trimmed.count - width))
        let from = trimmed.index(trimmed.startIndex, offsetBy: start)
        let to = trimmed.index(from, offsetBy: width)
        return (start > 0 ? "…" : "") + trimmed[from..<to] + (to < trimmed.endIndex ? "…" : "")
    }

    static func label(of text: String) -> String {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let heading = lines.prefix(8).first(where: isHeading) { return heading }
        guard let first = lines.first else { return "" }
        return first.count > 30 ? String(first.prefix(30)) + "…" : first
    }
}

/// How a file went to the model.
public enum FileDelivery: Equatable, Sendable {
    /// All of it.
    case whole
    /// The start and an outline; other sections on request.
    case paged(sections: Int)
    /// Only the first characters; the model can't ask for more.
    case truncated(characters: Int)
}

extension Assistant {
    /// A file as attached to a question, given `share` characters of the question's budget.
    /// With `canPage`, a file larger than its share is sent as its start plus an outline, and the
    /// model reads other sections through `read_file`; otherwise it is cut.
    public static func fileAttachment(title: String, text: String, extractionCut: Bool, share: Int,
                                      canPage: Bool) -> (Attachment, FileDelivery) {
        if text.count <= share && !extractionCut {
            return (Attachment(title: title, text: text), .whole)
        }
        guard canPage else {
            let sent = min(share, text.count)
            return (Attachment(title: title, text: String(text.prefix(sent)), truncated: true), .truncated(characters: sent))
        }
        let document = DocumentSections(text: text)
        // Whole leading sections that fit, or the start of the first.
        var included = 0
        var used = 0
        for section in document.sections {
            guard used + section.count <= share else { break }
            used += section.count
            included += 1
        }
        let body: String
        let opening: String
        if included == 0 {
            body = String(document.sections.first?.prefix(share) ?? "")
            opening = "下面是第 1 段的前面部分"
        } else {
            body = document.sections.prefix(included).enumerated()
                .map { "〔第 \($0.offset + 1) 段〕\n\($0.element)" }.joined(separator: "\n\n")
            opening = included == 1 ? "下面是第 1 段" : "下面是第 1 到 \(included) 段"
        }
        let more = extractionCut ? "（文件过长，只读取了前 \(document.count) 段）" : ""
        let text = """
        共 \(document.count) 段\(more)，\(opening)。其他内容需要时用 search_file 搜索关键词，或用 read_file 读取某一段，够回答就不必再找。
        目录：
        \(document.outline)

        \(body)
        """
        return (Attachment(title: title, text: text), .paged(sections: document.count))
    }
}
