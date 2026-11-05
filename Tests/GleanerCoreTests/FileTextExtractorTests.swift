import AppKit
import Foundation
import Testing
@testable import GleanerCore

@Suite struct FileTextExtractorTests {
    private let dir: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("files-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Builds a zip-based Office file from XML parts with the system `zip`.
    private func office(_ name: String, parts: [String: String]) throws -> URL {
        let root = dir.appendingPathComponent(name + "-parts")
        for (path, xml) in parts {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try xml.write(to: file, atomically: true, encoding: .utf8)
        }
        let output = dir.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = root
        process.arguments = ["-qr", output.path] + parts.keys.sorted()
        try process.run()
        process.waitUntilExit()
        return output
    }

    @Test func plainTextAndTruncation() throws {
        let file = dir.appendingPathComponent("note.txt")
        try "第一行\n\n\n第二行  \n".write(to: file, atomically: true, encoding: .utf8)
        #expect(try FileTextExtractor.extract(from: file) == .init(text: "第一行\n\n第二行", truncated: false))
        let cut = try FileTextExtractor.extract(from: file, limit: 3)
        #expect(cut.truncated && cut.text == "第一行")
    }

    @Test func wordDocument() throws {
        let source = dir.appendingPathComponent("source.txt")
        try "季度报告\n回款 120 万".write(to: source, atomically: true, encoding: .utf8)
        let docx = dir.appendingPathComponent("report.docx")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "docx", source.path, "-output", docx.path]
        try process.run()
        process.waitUntilExit()
        let text = try FileTextExtractor.extract(from: docx).text
        #expect(text.contains("季度报告") && text.contains("回款 120 万"))
    }

    @Test func spreadsheet() throws {
        let xlsx = try office("book.xlsx", parts: [
            "xl/sharedStrings.xml": #"<sst><si><t>项目</t></si><si><t>金额</t></si><si><r><t>回</t></r><r><t>款</t></r></si></sst>"#,
            "xl/worksheets/sheet1.xml": #"<worksheet><sheetData><row><c t="s"><v>0</v></c><c t="s"><v>1</v></c></row><row><c t="s"><v>2</v></c><c><v>120</v></c></row></sheetData></worksheet>"#,
        ])
        #expect(try FileTextExtractor.extract(from: xlsx).text == "【工作表 1】\n项目\t金额\n回款\t120")
    }

    @Test func slides() throws {
        let pptx = try office("deck.pptx", parts: [
            "ppt/slides/slide1.xml": #"<p:sld><a:p><a:r><a:t>封面</a:t></a:r></a:p></p:sld>"#,
            "ppt/slides/slide2.xml": #"<p:sld><a:p><a:r><a:t>目标</a:t></a:r><a:r><a:t>：增长</a:t></a:r></a:p><a:p><a:r><a:t>下一步</a:t></a:r></a:p></p:sld>"#,
            "ppt/slides/slide10.xml": #"<p:sld><a:p><a:r><a:t>结尾</a:t></a:r></a:p></p:sld>"#,
        ])
        #expect(try FileTextExtractor.extract(from: pptx).text
                == "【第 1 页】\n封面\n\n【第 2 页】\n目标：增长\n下一步\n\n【第 3 页】\n结尾")
    }

    @Test func pdfTextLayer() throws {
        let pdf = dir.appendingPathComponent("doc.pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let context = CGContext(pdf as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Invoice 2026 total 480",
                                                                       attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        context.textPosition = CGPoint(x: 20, y: 100)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        #expect(try FileTextExtractor.extract(from: pdf).text.contains("Invoice 2026 total 480"))
    }

    @Test func rejectsUnknownAndEmpty() throws {
        let zip = dir.appendingPathComponent("archive.zip")
        try Data([1, 2, 3]).write(to: zip)
        #expect(!FileTextExtractor.canExtract(zip))
        #expect(throws: FileTextExtractor.Failure.unsupported) { try FileTextExtractor.extract(from: zip) }
        let blank = dir.appendingPathComponent("blank.txt")
        try "  \n".write(to: blank, atomically: true, encoding: .utf8)
        #expect(throws: FileTextExtractor.Failure.empty) { try FileTextExtractor.extract(from: blank) }
    }
}
