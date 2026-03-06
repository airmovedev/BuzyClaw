import AppKit
import UniformTypeIdentifiers
import PDFKit

struct PendingAttachment: Identifiable {
    enum Kind {
        case imageDataURL(String)
        case text(fileName: String, content: String)
    }

    let id = UUID()
    let fileName: String
    let kind: Kind
    let previewImage: NSImage?
    let sourceURL: URL?

    var displayText: String {
        switch kind {
        case .imageDataURL:
            return "[图片附件] \(fileName)"
        case .text(let name, _):
            return "[文件附件] \(name)"
        }
    }

    static func from(url: URL) throws -> PendingAttachment {
        let ext = url.pathExtension.lowercased()
        let fileName = url.lastPathComponent

        if ["png", "jpg", "jpeg", "gif", "webp"].contains(ext) {
            let data = try Data(contentsOf: url)
            let mime = switch ext {
            case "png": "image/png"
            case "gif": "image/gif"
            case "webp": "image/webp"
            default: "image/jpeg"
            }
            let base64 = data.base64EncodedString()
            let dataURL = "data:\(mime);base64,\(base64)"
            return PendingAttachment(fileName: fileName, kind: .imageDataURL(dataURL), previewImage: NSImage(contentsOf: url), sourceURL: url)
        }

        if ext == "pdf" {
            guard let pdf = PDFDocument(url: url) else {
                throw NSError(domain: "ChatView", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法读取 PDF"])
            }
            let allText = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
            return PendingAttachment(fileName: fileName, kind: .text(fileName: fileName, content: allText), previewImage: nil, sourceURL: url)
        }

        let content = try String(contentsOf: url, encoding: .utf8)
        return PendingAttachment(fileName: fileName, kind: .text(fileName: fileName, content: content), previewImage: nil, sourceURL: url)
    }
}
