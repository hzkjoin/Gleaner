import Foundation

/// File types whose text Gleaner can read. Also compiled into the Finder extension, so it must
/// not depend on anything else in GleanerCore.
public enum ReadableFileTypes {
    public static let plainText: Set<String> = ["txt", "md", "markdown", "csv", "tsv", "json", "log", "xml", "yaml", "yml"]
    /// Formats `textutil` converts.
    public static let documents: Set<String> = ["doc", "docx", "rtf", "rtfd", "odt", "html", "htm", "webarchive", "wordml"]
    /// Read through text recognition.
    public static let images: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "bmp", "tif", "tiff", "webp"]
    public static let others: Set<String> = ["pdf", "xlsx", "pptx"]

    public static let all = plainText.union(documents).union(images).union(others)

    public static func contains(_ url: URL) -> Bool {
        all.contains(url.pathExtension.lowercased())
    }
}
