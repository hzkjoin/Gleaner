import Foundation

/// Extracts readable text from a raw email (RFC 822 / MIME), as stored in Mail's `.emlx` files.
///
/// Prefers a `text/plain` part, falls back to `text/html` with the markup removed, and decodes
/// base64, quoted-printable and the declared charset (GBK/GB2312 read as GB18030).
public enum MailMessageText {
    /// The text of an `.emlx` file: a byte count on the first line, then the message.
    public static func text(fromEMLX data: Data, limit: Int = 2000) -> String? {
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return text(fromMessage: data, limit: limit) }
        let countText = String(decoding: data[data.startIndex..<newline], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        var message = data[data.index(after: newline)...]
        if let count = Int(countText), count <= message.count { message = message.prefix(count) }
        return text(fromMessage: Data(message), limit: limit)
    }

    public static func text(fromMessage data: Data, limit: Int = 2000) -> String? {
        guard let part = Part(data) else { return nil }
        let raw = bestText(in: part) ?? ""
        let cleaned = collapse(raw)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(limit))
    }

    // MARK: - MIME

    struct Part {
        var headers: [String: String]
        var body: Data

        init?(_ data: Data) {
            // Headers end at the first blank line (CRLF CRLF or LF LF).
            let bytes = [UInt8](data)
            var split: (header: Int, body: Int)?
            var index = 0
            while index < bytes.count {
                if bytes[index] == 10 {
                    if index + 1 < bytes.count, bytes[index + 1] == 10 { split = (index, index + 2); break }
                    if index + 2 < bytes.count, bytes[index + 1] == 13, bytes[index + 2] == 10 { split = (index, index + 3); break }
                }
                index += 1
            }
            guard let split else { return nil }
            let headerText = String(decoding: bytes[0..<split.header], as: UTF8.self)
            headers = Self.parseHeaders(headerText)
            body = Data(bytes[split.body...])
        }

        static func parseHeaders(_ text: String) -> [String: String] {
            var result: [String: String] = [:]
            var current: (name: String, value: String)?
            for rawLine in text.components(separatedBy: "\n") {
                let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
                if let first = line.first, first == " " || first == "\t", current != nil {
                    current!.value += " " + line.trimmingCharacters(in: .whitespaces)
                    continue
                }
                if let current { result[current.name] = current.value }
                guard let colon = line.firstIndex(of: ":") else { current = nil; continue }
                current = (line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }
            if let current { result[current.name] = current.value }
            return result
        }

        var contentType: String {
            (headers["content-type"] ?? "text/plain").split(separator: ";").first.map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            } ?? "text/plain"
        }

        func parameter(_ name: String) -> String? {
            guard let header = headers["content-type"] else { return nil }
            for piece in header.split(separator: ";").dropFirst() {
                let pair = piece.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if pair.count == 2, pair[0].lowercased() == name {
                    return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
            }
            return nil
        }

        var children: [Part] {
            guard contentType.hasPrefix("multipart/"), let boundary = parameter("boundary") else { return [] }
            // Split the raw bytes: parts may use different charsets.
            return Self.split(body, boundary: boundary).compactMap(Part.init)
        }

        static func split(_ data: Data, boundary: String) -> [Data] {
            let marker = Data("--\(boundary)".utf8)
            var parts: [Data] = []
            var searchStart = data.startIndex
            var partStart: Data.Index?
            while let range = data.range(of: marker, in: searchStart..<data.endIndex) {
                if let start = partStart { parts.append(data[start..<range.lowerBound]) }
                var next = range.upperBound
                // A closing boundary ends with "--".
                if data[next...].starts(with: Data("--".utf8)) { partStart = nil; break }
                while next < data.endIndex, data[next] == 13 || data[next] == 10 || data[next] == 32 || data[next] == 9 {
                    if data[next] == 10 { next = data.index(after: next); break }
                    next = data.index(after: next)
                }
                partStart = next
                searchStart = next
            }
            if let start = partStart, start < data.endIndex { parts.append(data[start...]) }
            return parts.map { Data($0) }
        }

        /// The body decoded from its transfer encoding and charset.
        var decodedText: String {
            let encoding = (headers["content-transfer-encoding"] ?? "").lowercased()
            let bytes: Data
            if encoding.contains("base64") {
                let compact = String(decoding: body, as: UTF8.self).filter { !$0.isWhitespace }
                bytes = Data(base64Encoded: compact, options: .ignoreUnknownCharacters) ?? body
            } else if encoding.contains("quoted-printable") {
                bytes = MailMessageText.decodeQuotedPrintable(body)
            } else {
                bytes = body
            }
            return MailMessageText.decode(bytes, charset: parameter("charset"))
        }
    }

    static func bestText(in part: Part) -> String? {
        let type = part.contentType
        if type.hasPrefix("multipart/") {
            let children = part.children
            // Prefer plain text anywhere in the tree, then HTML.
            for child in children where child.contentType == "text/plain" {
                let text = child.decodedText
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
            }
            for child in children {
                if child.contentType.hasPrefix("multipart/"), let text = bestText(in: child) { return text }
            }
            for child in children where child.contentType == "text/html" {
                return stripHTML(child.decodedText)
            }
            return nil
        }
        if type == "text/plain" { return part.decodedText }
        if type == "text/html" { return stripHTML(part.decodedText) }
        return nil
    }

    static func decodeQuotedPrintable(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 55
            case 97...102: return byte - 87
            default: return nil
            }
        }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 61 {  // "="
                if index + 1 < bytes.count, bytes[index + 1] == 10 { index += 2; continue }  // soft break
                if index + 2 < bytes.count, bytes[index + 1] == 13, bytes[index + 2] == 10 { index += 3; continue }
                if index + 2 < bytes.count, let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) {
                    output.append(high << 4 | low)
                    index += 3
                    continue
                }
            }
            output.append(byte)
            index += 1
        }
        return Data(output)
    }

    static func decode(_ data: Data, charset: String?) -> String {
        let name = (charset ?? "utf-8").lowercased()
        let iana = ["gb2312", "gbk", "x-gbk", "gb_2312-80"].contains(name) ? "gb18030" : name
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(iana as CFString)
        if cfEncoding != kCFStringEncodingInvalidId {
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func stripHTML(_ html: String) -> String {
        var text = html
        for tag in ["style", "script", "head"] {
            text = text.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<(br|/p|/div|/tr|/li|/h[1-6])[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value, options: .caseInsensitive) }
        // Numeric entities.
        let pattern = try! NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let isHex = ns.substring(with: match.range(at: 1)) == "x"
            let digits = ns.substring(with: match.range(at: 2))
            if let value = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(value) {
                result.append(Character(scalar))
            }
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// Trims each line, drops quoted replies' blank runs, and collapses spaces.
    static func collapse(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r", with: "")
            .components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "[ \t\u{00A0}\u{3000}]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces) }
        var result: [String] = []
        for line in lines where !(line.isEmpty && (result.last?.isEmpty ?? true)) { result.append(line) }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
