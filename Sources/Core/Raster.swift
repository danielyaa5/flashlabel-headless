import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum RotateMode: Equatable {
    case auto
    case degrees(Int)  // clockwise: 0, 90, 180, 270
}

enum CropMode: Equatable {
    case auto
    case none
    case rect(CGRect)  // source units (PDF points or image pixels), origin top-left
}

struct RasterOptions: Equatable {
    var page: Int = 1
    var rotate: RotateMode = .auto
    var crop: CropMode = .auto
    var threshold: Int = 128
}

/// What the rasterizer decided, for logging and tests.
struct RasterReport: Equatable {
    var sourceKind: String
    var sourceSize: CGSize
    var cropRect: CGRect  // top-left origin, source units
    var cropWasAuto: Bool
    var rotation: Int
    var scale: CGFloat  // dots per source unit
}

/// A drawable input: one PDF page or one bitmap image.
struct LabelSource {
    let kind: String
    let size: CGSize  // after applying the PDF page's own /Rotate
    let draw: (CGContext) -> Void  // draws into [0, size] with a bottom-left origin

    static func load(url: URL, page: Int) throws -> LabelSource {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FlashLabelError.input("file not found: \(url.path)")
        }
        if url.pathExtension.lowercased() == "pdf" { return try pdf(url: url, page: page) }
        return try image(url: url)
    }

    static func pdf(url: URL, page pageNumber: Int) throws -> LabelSource {
        guard let doc = CGPDFDocument(url as CFURL) else { throw FlashLabelError.input("cannot open PDF: \(url.lastPathComponent)") }
        if doc.isEncrypted, !doc.unlockWithPassword("") { throw FlashLabelError.input("PDF is password protected") }
        guard pageNumber >= 1, pageNumber <= doc.numberOfPages, let page = doc.page(at: pageNumber) else {
            throw FlashLabelError.input("page \(pageNumber) out of range (PDF has \(doc.numberOfPages) page(s))")
        }
        let box = page.getBoxRect(.cropBox)
        let angle = ((page.rotationAngle % 360) + 360) % 360
        let size = (angle == 90 || angle == 270) ? CGSize(width: box.height, height: box.width) : box.size
        return LabelSource(kind: "pdf", size: size) { ctx in
            let rect = CGRect(origin: .zero, size: size)
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.concatenate(page.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
            ctx.drawPDFPage(page)
            ctx.restoreGState()
        }
    }

    static func image(url: URL) throws -> LabelSource {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw FlashLabelError.input("unsupported or unreadable image: \(url.lastPathComponent)")
        }
        let size = CGSize(width: img.width, height: img.height)
        return LabelSource(kind: "image", size: size) { ctx in
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(origin: .zero, size: size))
        }
    }
}

enum Rasterizer {
    /// Renders a source into a TSPL-ready bitmap sized for the label.
    static func rasterize(_ source: LabelSource, spec: LabelSpec, options: RasterOptions) throws -> (MonoBitmap, RasterReport) {
        guard source.size.width >= 1, source.size.height >= 1 else { throw FlashLabelError.input("source has no drawable area") }
        guard (1...254).contains(options.threshold) else { throw FlashLabelError.usage("threshold must be 1-254") }
        let labelW = spec.widthDots, labelH = spec.heightDots

        // 1. Crop.
        var crop = CGRect(origin: .zero, size: source.size)
        var cropWasAuto = false
        switch options.crop {
        case .none:
            break
        case .rect(let r):
            let full = CGRect(origin: .zero, size: source.size)
            crop = r.intersection(full)
            guard !crop.isNull, crop.width >= 1, crop.height >= 1 else {
                throw FlashLabelError.usage("crop rectangle lies outside the \(fmt(Double(source.size.width)))x\(fmt(Double(source.size.height))) source")
            }
        case .auto:
            if !aspectMatchesLabel(source.size, labelW: labelW, labelH: labelH), let content = contentBounds(source) {
                let pad = max(2, 0.01 * max(source.size.width, source.size.height))
                crop = content.insetBy(dx: -pad, dy: -pad).intersection(CGRect(origin: .zero, size: source.size))
                cropWasAuto = true
            }
        }

        // 2. Rotation (clockwise degrees).
        var rotation = 0
        switch options.rotate {
        case .degrees(let d):
            guard [0, 90, 180, 270].contains(d) else { throw FlashLabelError.usage("rotate must be auto, 0, 90, 180 or 270") }
            rotation = d
        case .auto:
            let cropLandscape = crop.width > crop.height * 1.02
            let cropPortrait = crop.height > crop.width * 1.02
            let labelPortrait = labelH > labelW
            if (labelPortrait && cropLandscape) || (!labelPortrait && labelW > labelH && cropPortrait) { rotation = 90 }
        }

        // 3. Fit (preserve aspect ratio, center).
        let rotatedW = (rotation == 90 || rotation == 270) ? crop.height : crop.width
        let rotatedH = (rotation == 90 || rotation == 270) ? crop.width : crop.height
        let scale = min(CGFloat(labelW) / rotatedW, CGFloat(labelH) / rotatedH)

        // 4. Render into an 8-bit gray canvas at printer resolution, then threshold.
        let cropBL = CGRect(x: crop.minX, y: source.size.height - crop.maxY, width: crop.width, height: crop.height)
        let gray = try renderGray(width: labelW, height: labelH) { ctx in
            ctx.translateBy(x: CGFloat(labelW) / 2, y: CGFloat(labelH) / 2)
            ctx.scaleBy(x: scale, y: scale)
            ctx.rotate(by: -CGFloat(rotation) * .pi / 180)
            ctx.translateBy(x: -cropBL.midX, y: -cropBL.midY)
            ctx.clip(to: cropBL)
            source.draw(ctx)
        }
        var bitmap = MonoBitmap(width: labelW, height: labelH)
        let t = UInt8(options.threshold)
        for y in 0..<labelH {
            let row = y * labelW
            for x in 0..<labelW where gray[row + x] < t { bitmap.setBlack(x: x, y: y) }
        }
        let report = RasterReport(sourceKind: source.kind, sourceSize: source.size, cropRect: crop,
                                  cropWasAuto: cropWasAuto, rotation: rotation, scale: scale)
        return (bitmap, report)
    }

    /// True when the page already has the label's shape (either orientation), within 3%.
    static func aspectMatchesLabel(_ size: CGSize, labelW: Int, labelH: Int) -> Bool {
        let la = Double(labelW) / Double(labelH)
        let sa = Double(size.width / size.height)
        return abs(sa - la) / la < 0.03 || abs(sa - 1 / la) / (1 / la) < 0.03
    }

    /// Bounding box of non-white content in source units (top-left origin), or nil for a blank source.
    static func contentBounds(_ source: LabelSource) -> CGRect? {
        let longest = max(source.size.width, source.size.height)
        let k = min(4, 1600 / longest)
        let w = max(1, Int((source.size.width * k).rounded())), h = max(1, Int((source.size.height * k).rounded()))
        guard let gray = try? renderGray(width: w, height: h, draw: { ctx in
            ctx.scaleBy(x: CGFloat(w) / source.size.width, y: CGFloat(h) / source.size.height)
            source.draw(ctx)
        }) else { return nil }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = y * w
            for x in 0..<w where gray[row + x] < 200 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let sx = source.size.width / CGFloat(w), sy = source.size.height / CGFloat(h)
        return CGRect(x: CGFloat(minX) * sx, y: CGFloat(minY) * sy,
                      width: CGFloat(maxX - minX + 1) * sx, height: CGFloat(maxY - minY + 1) * sy)
    }

    /// Renders into a white 8-bit grayscale buffer. Row 0 of the result is the top of the image.
    static func renderGray(width: Int, height: Int, draw: (CGContext) -> Void) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 255, count: width * height)
        let ok: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            draw(ctx)
            return true
        }
        guard ok else { throw FlashLabelError.input("could not create a \(width)x\(height) render buffer") }
        return buffer
    }
}

enum PreviewWriter {
    /// Writes the exact dots that will be printed as a black-and-white PNG.
    static func writePNG(_ bitmap: MonoBitmap, to url: URL) throws {
        var gray = [UInt8](repeating: 255, count: bitmap.width * bitmap.height)
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width where bitmap.isBlack(x: x, y: y) { gray[y * bitmap.width + x] = 0 }
        }
        guard let provider = CGDataProvider(data: Data(gray) as CFData),
              let image = CGImage(width: bitmap.width, height: bitmap.height, bitsPerComponent: 8, bitsPerPixel: 8,
                                  bytesPerRow: bitmap.width, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw FlashLabelError.input("cannot write preview to \(url.path)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw FlashLabelError.input("cannot write preview to \(url.path)") }
    }
}
