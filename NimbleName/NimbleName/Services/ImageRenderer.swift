import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Renders the first PDF page or downsizes an image, returning JPEG data sized for the model.
nonisolated enum ImageRenderer {
    static let maxPixelSize = 1600
    static let jpegQuality = 0.85

    enum RenderError: LocalizedError {
        case cannotOpen(String)
        case noPage
        case contextFailed
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .cannotOpen(let name): "Cannot open \(name)"
            case .noPage: "PDF has no pages"
            case .contextFailed: "Could not render the document"
            case .encodeFailed: "Could not encode the image"
            }
        }
    }

    @concurrent
    static func renderJPEG(from url: URL) async throws -> Data {
        let image: CGImage
        if url.pathExtension.lowercased() == "pdf" {
            image = try renderPDF(url)
        } else {
            image = try loadImage(url)
        }
        return try encodeJPEG(image)
    }

    private static func renderPDF(_ url: URL) throws -> CGImage {
        guard let document = CGPDFDocument(url as CFURL) else {
            throw RenderError.cannotOpen(url.lastPathComponent)
        }
        guard let page = document.page(at: 1) else { throw RenderError.noPage }

        let box = page.getBoxRect(.mediaBox)
        let rotated = (page.rotationAngle / 90) % 2 != 0
        let pageWidth = rotated ? box.height : box.width
        let pageHeight = rotated ? box.width : box.height
        let scale = CGFloat(maxPixelSize) / max(pageWidth, pageHeight, 1)
        let width = max(1, Int((pageWidth * scale).rounded()))
        let height = max(1, Int((pageHeight * scale).rounded()))

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw RenderError.contextFailed }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        context.concatenate(page.getDrawingTransform(.mediaBox, rect: target, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)

        guard let image = context.makeImage() else { throw RenderError.contextFailed }
        return image
    }

    private static func loadImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw RenderError.cannotOpen(url.lastPathComponent)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw RenderError.cannotOpen(url.lastPathComponent)
        }
        return image
    }

    private static func encodeJPEG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw RenderError.encodeFailed
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: jpegQuality]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw RenderError.encodeFailed }
        return data as Data
    }
}
