import AppKit
import Foundation
import PDFKit
import Vision

/// Pulls readable text out of a received file, on this Mac: PDF, Word, RTF, Excel, PowerPoint,
/// plain text, and images (through text recognition).
public enum FileTextExtractor {
    public struct Content: Equatable, Sendable {
        public var text: String
        /// Only the beginning was kept.
        public var truncated: Bool

        public init(text: String, truncated: Bool) {
            self.text = text
            self.truncated = truncated
        }
    }

    public enum Failure: LocalizedError, Equatable {
        case unsupported
        case unreadable
        case empty

        public var errorDescription: String? {
            switch self {
            case .unsupported: return "不支持这种文件"
            case .unreadable: return "无法读取这个文件"
            case .empty: return "文件里没有可读的文字"
            }
        }
    }

    static let plainText: Set<String> = ["txt", "md", "markdown", "csv", "tsv", "json", "log", "xml", "yaml", "yml"]
    /// Formats `textutil` converts.
    static let documents: Set<String> = ["doc", "docx", "rtf", "rtfd", "odt", "html", "htm", "webarchive", "wordml"]
    public static let images: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "bmp", "tif", "tiff", "webp"]

    public static func canExtract(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return plainText.contains(ext) || documents.contains(ext) || images.contains(ext)
            || ["pdf", "xlsx", "pptx"].contains(ext)
    }

    /// Text of the file, cut to `limit` characters. Slow for scanned documents and images.
    public static func extract(from url: URL, limit: Int = 20_000) throws -> Content {
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw Failure.unreadable }
        let ext = url.pathExtension.lowercased()
        let raw: String
        if plainText.contains(ext) {
            raw = try readPlainText(url)
        } else if documents.contains(ext) {
            raw = try run("/usr/bin/textutil", ["-convert", "txt", "-stdout", url.path])
        } else if ext == "pdf" {
            raw = try readPDF(url)
        } else if ext == "xlsx" {
            raw = try readSpreadsheet(url)
        } else if ext == "pptx" {
            raw = try readSlides(url)
        } else if images.contains(ext) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure.unreadable }
            raw = recognizeText(in: image)
        } else {
            throw Failure.unsupported
        }
        let text = tidy(raw)
        guard !text.isEmpty else { throw Failure.empty }
        return text.count > limit ? Content(text: String(text.prefix(limit)), truncated: true) : Content(text: text, truncated: false)
    }

    // MARK: - Formats

    static func readPlainText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) { return text }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        return String(data: data, encoding: gb18030) ?? String(decoding: data, as: UTF8.self)
    }

    /// The text layer; pages without one (scans) go through text recognition, up to 10 pages.
    static func readPDF(_ url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else { throw Failure.unreadable }
        var pages: [String] = []
        var recognized = 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            var text = page.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 10, recognized < 10 {
                recognized += 1
                let bounds = page.bounds(for: .mediaBox)
                let image = page.thumbnail(of: NSSize(width: bounds.width * 2, height: bounds.height * 2), for: .mediaBox)
                if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    text = recognizeText(in: cgImage)
                }
            }
            pages.append(text)
        }
        return pages.joined(separator: "\n\n")
    }

    /// Cells of each worksheet, a row per line, tab between cells.
    static func readSpreadsheet(_ url: URL) throws -> String {
        let entries = try zipEntries(url)
        let shared = entries.contains("xl/sharedStrings.xml")
            ? XMLText.sharedStrings(try unzip(url, entry: "xl/sharedStrings.xml")) : []
        let sheets = entries.filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard !sheets.isEmpty else { throw Failure.unreadable }
        return try sheets.enumerated().map { index, entry in
            let rows = XMLText.sheetRows(try unzip(url, entry: entry), shared: shared)
            return "【工作表 \(index + 1)】\n" + rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// Text of each slide, in order.
    static func readSlides(_ url: URL) throws -> String {
        let slides = try zipEntries(url).filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard !slides.isEmpty else { throw Failure.unreadable }
        return try slides.enumerated().map { index, entry in
            "【第 \(index + 1) 页】\n" + XMLText.paragraphs(try unzip(url, entry: entry), text: "a:t", paragraph: "a:p")
        }.joined(separator: "\n\n")
    }

    static func recognizeText(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    // MARK: - Helpers

    static func zipEntries(_ url: URL) throws -> [String] {
        try run("/usr/bin/unzip", ["-Z1", url.path]).split(separator: "\n").map(String.init)
    }

    static func unzip(_ url: URL, entry: String) throws -> Data {
        try runData("/usr/bin/unzip", ["-p", url.path, entry])
    }

    static func run(_ tool: String, _ arguments: [String]) throws -> String {
        String(decoding: try runData(tool, arguments), as: UTF8.self)
    }

    static func runData(_ tool: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.unreadable }
        return data
    }

    /// Trims lines and collapses runs of blank lines.
    static func tidy(_ text: String) -> String {
        var lines: [String] = []
        for line in text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty && (lines.last?.isEmpty ?? true) { continue }
            lines.append(trimmed)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Text from Office Open XML parts.
enum XMLText {
    /// `xl/sharedStrings.xml`: one string per `<si>`.
    static func sharedStrings(_ data: Data) -> [String] {
        let collector = Collector(textTags: ["t"], itemTag: "si")
        collector.parse(data)
        return collector.items
    }

    /// A worksheet's rows, resolving shared strings.
    static func sheetRows(_ data: Data, shared: [String]) -> [[String]] {
        let collector = SheetCollector(shared: shared)
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.parse()
        return collector.rows.filter { row in row.contains { !$0.isEmpty } }
    }

    /// Text runs grouped into paragraphs.
    static func paragraphs(_ data: Data, text: String, paragraph: String) -> String {
        let collector = Collector(textTags: [text], itemTag: paragraph)
        collector.parse(data)
        return collector.items.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private final class Collector: NSObject, XMLParserDelegate {
        let textTags: Set<String>
        let itemTag: String
        var items: [String] = []
        private var current = ""
        private var inText = false

        init(textTags: Set<String>, itemTag: String) {
            self.textTags = textTags
            self.itemTag = itemTag
        }

        func parse(_ data: Data) {
            let parser = XMLParser(data: data)
            parser.delegate = self
            parser.parse()
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            if name == itemTag { current = "" }
            if textTags.contains(name) { inText = true }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { current += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if textTags.contains(name) { inText = false }
            if name == itemTag { items.append(current) }
        }
    }

    private final class SheetCollector: NSObject, XMLParserDelegate {
        let shared: [String]
        var rows: [[String]] = []
        private var row: [String] = []
        private var cellType = ""
        private var value = ""
        private var inValue = false

        init(shared: [String]) { self.shared = shared }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            switch name {
            case "row": row = []
            case "c": cellType = attributes["t"] ?? ""; value = ""
            case "v", "t": inValue = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inValue { value += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "v", "t": inValue = false
            case "c":
                if cellType == "s", let index = Int(value), shared.indices.contains(index) {
                    row.append(shared[index])
                } else {
                    row.append(value)
                }
            case "row": rows.append(row)
            default: break
            }
        }
    }
}
