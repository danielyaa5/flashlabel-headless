import Foundation

/// Physical label and print settings, expressed the way TSPL expects them.
struct LabelSpec: Equatable {
    var widthMM: Double = 100
    var heightMM: Double = 150
    var gapMM: Double = 2
    var density: Int = 8
    var speed: Double = 4
    var copies: Int = 1
    var dotsPerMM: Int = 8
    var maxWidthDots: Int = 864
    var maxHeightDots: Int = 2400

    /// Printable width in dots, rounded down to a whole byte (TSPL BITMAP rows are byte-aligned).
    var widthDots: Int {
        let dots = Int((widthMM * Double(dotsPerMM)).rounded())
        return min(dots / 8 * 8, maxWidthDots / 8 * 8)
    }

    var heightDots: Int { min(Int((heightMM * Double(dotsPerMM)).rounded()), maxHeightDots) }
    var widthBytes: Int { widthDots / 8 }

    func validate() throws {
        guard widthMM > 0, heightMM > 0, widthDots >= 8, heightDots >= 1 else {
            throw FlashLabelError.usage("label size must be positive")
        }
        guard Int((widthMM * Double(dotsPerMM)).rounded()) <= maxWidthDots else {
            throw FlashLabelError.usage("label width \(fmt(widthMM)) mm exceeds the printer's \(maxWidthDots / dotsPerMM) mm print head")
        }
        guard Int((heightMM * Double(dotsPerMM)).rounded()) <= maxHeightDots else {
            throw FlashLabelError.usage("label height \(fmt(heightMM)) mm exceeds the printer's \(maxHeightDots / dotsPerMM) mm maximum")
        }
        guard gapMM >= 0, gapMM <= 25 else { throw FlashLabelError.usage("gap must be between 0 and 25 mm") }
        guard (1...15).contains(density) else { throw FlashLabelError.usage("density must be 1-15") }
        guard speed >= 1, speed <= 12 else { throw FlashLabelError.usage("speed must be 1-12") }
        guard (1...100).contains(copies) else { throw FlashLabelError.usage("copies must be 1-100") }
    }
}

/// Formats a number without a trailing ".0" (TSPL accepts both, this keeps jobs readable).
func fmt(_ value: Double) -> String {
    if value == value.rounded() { return String(Int(value)) }
    var s = String(format: "%.2f", value)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s
}

/// A 1-bit image in TSPL BITMAP layout: rows top to bottom, MSB = leftmost dot, 0 = black, 1 = white.
struct MonoBitmap: Equatable {
    let width: Int
    let height: Int
    var bytes: [UInt8]

    var bytesPerRow: Int { width / 8 }

    init(width: Int, height: Int) {
        precondition(width > 0 && width % 8 == 0 && height > 0)
        self.width = width
        self.height = height
        bytes = [UInt8](repeating: 0xFF, count: width / 8 * height)
    }

    init(width: Int, height: Int, bytes: [UInt8]) {
        precondition(width % 8 == 0 && bytes.count == width / 8 * height)
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    func isBlack(x: Int, y: Int) -> Bool {
        bytes[y * bytesPerRow + x / 8] & (0x80 >> UInt8(x % 8)) == 0
    }

    mutating func setBlack(x: Int, y: Int) {
        bytes[y * bytesPerRow + x / 8] &= ~(0x80 >> UInt8(x % 8))
    }

    var blackDotCount: Int { bytes.reduce(0) { $0 + (8 - $1.nonzeroBitCount) } }
}

enum TSPL {
    static let lineEnd = "\r\n"

    /// Builds a complete single-bitmap TSPL job.
    static func job(spec: LabelSpec, bitmap: MonoBitmap) -> Data {
        var header = ""
        header += "SIZE \(fmt(spec.widthMM)) mm,\(fmt(spec.heightMM)) mm\r\n"
        header += "GAP \(fmt(spec.gapMM)) mm,0 mm\r\n"
        header += "DIRECTION 0,0\r\n"
        header += "REFERENCE 0,0\r\n"
        header += "DENSITY \(spec.density)\r\n"
        header += "SPEED \(fmt(spec.speed))\r\n"
        header += "CLS\r\n"
        header += "BITMAP 0,0,\(bitmap.bytesPerRow),\(bitmap.height),0,"
        var data = Data(header.utf8)
        data.append(contentsOf: bitmap.bytes)
        data.append(Data("\r\nPRINT \(spec.copies),1\r\n".utf8))
        return data
    }

    /// Finds the first mode-0 BITMAP command in a TSPL job and returns its image.
    static func extractBitmap(from job: Data) -> MonoBitmap? {
        let bytes = [UInt8](job)
        let marker = [UInt8]("BITMAP ".utf8)
        guard let start = find(marker, in: bytes, from: 0) else { return nil }
        var i = start + marker.count
        var fields: [Int] = []
        var current = ""
        while i < bytes.count, fields.count < 5 {
            let c = bytes[i]
            if c == UInt8(ascii: ",") {
                guard let v = Int(current.trimmingCharacters(in: .whitespaces)) else { return nil }
                fields.append(v)
                current = ""
            } else {
                current.append(Character(UnicodeScalar(c)))
                if current.count > 12 { return nil }
            }
            i += 1
        }
        guard fields.count == 5, fields[4] == 0 else { return nil }
        let widthBytes = fields[2], height = fields[3]
        guard widthBytes > 0, height > 0 else { return nil }
        let count = widthBytes * height
        guard i + count <= bytes.count else { return nil }
        return MonoBitmap(width: widthBytes * 8, height: height, bytes: Array(bytes[i..<(i + count)]))
    }

    /// Returns the copy count of the last PRINT command, if any.
    static func printCopies(in job: Data) -> Int? {
        guard let text = String(data: job.suffix(64), encoding: .isoLatin1),
              let range = text.range(of: "PRINT ", options: .backwards) else { return nil }
        let rest = text[range.upperBound...]
        return Int(rest.prefix { $0.isNumber })
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8], from: Int) -> Int? {
        guard needle.count <= hay.count else { return nil }
        var i = from
        while i + needle.count <= hay.count {
            if hay[i] == needle[0], Array(hay[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }
}

enum FlashLabelError: Error, CustomStringConvertible {
    case usage(String)
    case input(String)
    case printerNotFound(String)
    case handshake(String)
    case transfer(String)
    case timeout(String)
    case bluetooth(String)

    var description: String {
        switch self {
        case .usage(let s), .input(let s), .printerNotFound(let s), .handshake(let s),
             .transfer(let s), .timeout(let s), .bluetooth(let s):
            return s
        }
    }

    var exitCode: Int32 {
        switch self {
        case .usage: return 1
        case .input: return 2
        case .printerNotFound: return 3
        case .handshake: return 4
        case .transfer: return 5
        case .timeout: return 6
        case .bluetooth: return 7
        }
    }
}
