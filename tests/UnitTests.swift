import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Offline tests. Nothing here touches Bluetooth.
// Build and run through tests/run.sh.

var failures = 0
var passes = 0

func check(_ cond: @autoclosure () -> Bool, _ msg: String, file: String = #file, line: Int = #line) {
    if cond() {
        passes += 1
    } else {
        failures += 1
        print("FAIL \((file as NSString).lastPathComponent):\(line): \(msg)")
    }
}

func expectThrows(_ msg: String, _ body: () throws -> Void) {
    do {
        try body()
        failures += 1
        print("FAIL: expected error: \(msg)")
    } catch {
        passes += 1
    }
}

func test(_ name: String, _ body: () throws -> Void) {
    let before = failures
    do { try body() } catch {
        failures += 1
        print("FAIL \(name): threw \(error)")
    }
    print("\(failures == before ? "ok  " : "FAIL") \(name)")
}

// MARK: Synthetic fixtures (fake shipping-label artwork, no real data)

enum Fixtures {
    /// Deterministic pseudo-random generator so fixtures are identical on every run.
    struct LCG {
        var state: UInt32
        mutating func next() -> UInt32 {
            state = state &* 1_664_525 &+ 1_013_904_223
            return state
        }
    }

    /// Draws fake label artwork into `r` (bottom-left coordinates): border, a solid banner along
    /// the top edge, a 2D-code-like grid, and 1D barcode bars near the bottom.
    static func drawFakeLabel(_ ctx: CGContext, in r: CGRect) {
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.setStrokeColor(gray: 0, alpha: 1)
        ctx.setLineWidth(2)
        ctx.stroke(r.insetBy(dx: 4, dy: 4))
        let banner = r.height < r.width ? 0.1 * r.height : 30
        ctx.fill(CGRect(x: r.minX + 4, y: r.maxY - 4 - banner, width: r.width - 8, height: banner))
        var rng = LCG(state: 42)
        let cell: CGFloat = 4
        let gridOrigin = CGPoint(x: r.minX + 20, y: r.maxY - banner - 80)
        for gy in 0..<14 {
            for gx in 0..<14 where (rng.next() >> 16) % 2 == 0 || gx == 0 || gy == 0 {
                ctx.fill(CGRect(x: gridOrigin.x + CGFloat(gx) * cell, y: gridOrigin.y + CGFloat(gy) * cell, width: cell, height: cell))
            }
        }
        var x = r.minX + 24
        let barTop = r.minY + 0.28 * r.height, barBottom = r.minY + 0.12 * r.height
        while x < r.maxX - 30 {
            let w = CGFloat(1 + (rng.next() >> 16) % 4)
            ctx.fill(CGRect(x: x, y: barBottom, width: w, height: barTop - barBottom))
            x += w + CGFloat(1 + (rng.next() >> 16) % 3)
        }
    }

    static func writePDF(_ url: URL, size: CGSize, draw: (CGContext) -> Void) {
        var box = CGRect(origin: .zero, size: size)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        draw(ctx)
        ctx.endPDFPage()
        ctx.closePDF()
    }

    /// 4 x 6 in label PDF (288 x 432 pt).
    static func label4x6(_ url: URL) {
        writePDF(url, size: CGSize(width: 288, height: 432)) { drawFakeLabel($0, in: CGRect(x: 0, y: 0, width: 288, height: 432)) }
    }

    /// US Letter page with a sideways (landscape) 6 x 4 in label in the upper half, the common
    /// layout of carrier and marketplace "print on plain paper" PDFs.
    static let letterLabelRect = CGRect(x: 90, y: 400, width: 432, height: 288)
    static func letterSideways(_ url: URL) {
        writePDF(url, size: CGSize(width: 612, height: 792)) { drawFakeLabel($0, in: letterLabelRect) }
    }

    /// Landscape 1200 x 800 px PNG of the same artwork.
    static func landscapePNG(_ url: URL) {
        let w = 1200, h = 800
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        drawFakeLabel(ctx, in: CGRect(x: 0, y: 0, width: w, height: h))
        let img = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        _ = CGImageDestinationFinalize(dest)
    }

    static func makeAll(in dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        label4x6(dir.appendingPathComponent("label-4x6.pdf"))
        letterSideways(dir.appendingPathComponent("label-letter.pdf"))
        landscapePNG(dir.appendingPathComponent("label-landscape.png"))
    }
}

func blackFraction(_ b: MonoBitmap, rows: ClosedRange<Int>, cols: ClosedRange<Int>) -> Double {
    var black = 0, total = 0
    for y in rows { for x in cols { total += 1; if b.isBlack(x: x, y: y) { black += 1 } } }
    return Double(black) / Double(total)
}

func bitmapBounds(_ b: MonoBitmap) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
    var minX = b.width, maxX = -1, minY = b.height, maxY = -1
    for y in 0..<b.height { for x in 0..<b.width where b.isBlack(x: x, y: y) {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    } }
    return maxX < 0 ? nil : (minX, maxX, minY, maxY)
}

// MARK: Tests

@main
struct TestRunner {
    static func main() {
        let args = CommandLine.arguments
        if args.count == 3, args[1] == "--make-fixtures" {
            Fixtures.makeAll(in: URL(fileURLWithPath: args[2]))
            print("fixtures written to \(args[2])")
            return
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("flashlabel-tests-\(getpid())")
        Fixtures.makeAll(in: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let spec = LabelSpec()

        test("label spec defaults match the A42BT 4x6 profile") {
            check(spec.widthDots == 800, "width dots \(spec.widthDots)")
            check(spec.heightDots == 1200, "height dots \(spec.heightDots)")
            check(spec.widthBytes == 100, "width bytes")
            check(spec.copies == 1, "default copies must be 1")
            try spec.validate()
            var wide = spec
            wide.widthMM = 110
            expectThrows("110 mm exceeds 864-dot head") { try wide.validate() }
            var dense = spec
            dense.density = 16
            expectThrows("density 16") { try dense.validate() }
        }

        test("bit polarity: MSB first, 0 = black, 1 = white") {
            var b = MonoBitmap(width: 16, height: 2)
            check(b.bytes == [UInt8](repeating: 0xFF, count: 4), "new bitmap is white")
            b.setBlack(x: 0, y: 0)
            b.setBlack(x: 9, y: 1)
            check(b.bytes == [0x7F, 0xFF, 0xFF, 0xBF], "packed bytes \(b.bytes)")
            check(b.isBlack(x: 0, y: 0) && b.isBlack(x: 9, y: 1) && !b.isBlack(x: 1, y: 0), "isBlack")
            check(b.blackDotCount == 2, "black count")
        }

        test("TSPL job layout and bitmap round trip") {
            var b = MonoBitmap(width: 800, height: 1200)
            for x in 0..<800 { b.setBlack(x: x, y: 0) }
            b.setBlack(x: 799, y: 1199)
            let job = TSPL.job(spec: spec, bitmap: b)
            let header = "SIZE 100 mm,150 mm\r\nGAP 2 mm,0 mm\r\nDIRECTION 0,0\r\nREFERENCE 0,0\r\nDENSITY 8\r\nSPEED 4\r\nCLS\r\nBITMAP 0,0,100,1200,0,"
            let trailer = "\r\nPRINT 1,1\r\n"
            check(job.starts(with: Data(header.utf8)), "header")
            check(job.suffix(trailer.utf8.count) == Data(trailer.utf8), "trailer")
            check(job.count == header.utf8.count + 120_000 + trailer.utf8.count, "length \(job.count)")
            let back = TSPL.extractBitmap(from: job)
            check(back == b, "extracted bitmap equals original")
            check(back?.bytes.count == 120_000, "120000 bitmap bytes")
            check(TSPL.printCopies(in: job) == 1, "PRINT 1,1")
            var s2 = spec
            s2.widthMM = 101.6
            s2.gapMM = 3.5
            s2.speed = 2.5
            s2.copies = 2
            let j2 = String(decoding: TSPL.job(spec: s2, bitmap: MonoBitmap(width: s2.widthDots, height: 8)).prefix(60), as: UTF8.self)
            check(j2.hasPrefix("SIZE 101.6 mm,150 mm\r\nGAP 3.5 mm,0 mm\r\n"), "decimal formatting: \(j2)")
            check(s2.widthDots == 808, "101.6 mm rounds down to whole bytes: \(s2.widthDots)")
        }

        test("credit gate parses FF03 notifications") {
            check(CreditGate.parse([0x01, 0x07]) == .grant(7), "grant")
            check(CreditGate.parse([0x02, 0xF4, 0x00]) == .payloadSize(244), "payload 244")
            check(CreditGate.parse([0x02, 0x00, 0x02]) == .payloadSize(512), "payload 512")
            check(CreditGate.parse([0x00, 0x00, 0x00, 0xF7, 0x01]) == .unknown([0, 0, 0, 0xF7, 1]), "unknown")
            var g = CreditGate()
            check(!g.handshakeComplete && !g.takeCredit(), "no credit before handshake")
            g.apply([0x01, 0x07])
            check(!g.handshakeComplete, "needs payload too")
            g.apply([0x02, 0xF4, 0x00])
            check(g.handshakeComplete && g.credits == 7 && g.payloadSize == 244, "handshake")
            for _ in 0..<7 { check(g.takeCredit(), "credit available") }
            check(!g.takeCredit() && g.credits == 0, "exhausted")
            check(!g.fullyReturned, "not drained")
            for _ in 0..<7 { g.apply([0x01, 0x01]) }
            check(g.fullyReturned && g.granted == 14 && g.consumed == 7, "drained")
        }

        test("credit-gated transfer never overruns the module and delivers every byte in order") {
            var job = Data()
            for i in 0..<120_127 { job.append(UInt8(truncatingIfNeeded: i &* 31 &+ 7)) }
            var g = CreditGate()
            g.apply([0x01, 0x07])
            g.apply([0x02, 0xF4, 0x00])
            var p = Packetizer(job)
            var moduleBuffer: [Data] = []
            var received = Data()
            var maxInFlight = 0, packets = 0, step = 0
            while !p.isFinished || !moduleBuffer.isEmpty {
                while g.credits > 0, !p.isFinished {
                    check(g.takeCredit(), "credit")
                    let chunk = p.next(maxLength: g.payloadSize)!
                    check(chunk.count <= 244, "packet size")
                    moduleBuffer.append(chunk)
                    packets += 1
                }
                maxInFlight = max(maxInFlight, moduleBuffer.count)
                step += 1
                // The module drains one or two packets per tick and returns a credit for each.
                for _ in 0..<(step % 3 == 0 ? 2 : 1) where !moduleBuffer.isEmpty {
                    received.append(moduleBuffer.removeFirst())
                    g.apply([0x01, 0x01])
                }
            }
            check(received == job, "payload intact")
            check(maxInFlight <= 7, "in flight \(maxInFlight) <= 7")
            check(packets == (job.count + 243) / 244, "packet count \(packets)")
            check(g.fullyReturned, "all credits returned")
        }

        test("4x6 PDF prints full page, upright, at 203 dpi") {
            let src = try LabelSource.load(url: tmp.appendingPathComponent("label-4x6.pdf"), page: 1)
            check(src.size == CGSize(width: 288, height: 432), "page size \(src.size)")
            let (b, r) = try Rasterizer.rasterize(src, spec: spec, options: RasterOptions())
            check(b.width == 800 && b.height == 1200, "dims")
            check(!r.cropWasAuto && r.rotation == 0, "no crop, no rotation: \(r)")
            // Banner along the top edge: 4..34 pt from top -> rows ~11..94.
            check(blackFraction(b, rows: 30...80, cols: 50...750) > 0.99, "top banner is solid black")
            check(blackFraction(b, rows: 560...640, cols: 300...500) == 0, "middle area is white")
            let bars = blackFraction(b, rows: 900...1050, cols: 100...700)
            check(bars > 0.25 && bars < 0.75, "barcode bars present (\(bars))")
        }

        test("sideways Letter PDF is auto-cropped to the label and rotated to portrait") {
            let src = try LabelSource.load(url: tmp.appendingPathComponent("label-letter.pdf"), page: 1)
            let (b, r) = try Rasterizer.rasterize(src, spec: spec, options: RasterOptions())
            check(r.cropWasAuto && r.rotation == 90, "auto crop + 90: \(r)")
            let expectTop = 792 - Fixtures.letterLabelRect.maxY
            check(abs(r.cropRect.minX - Fixtures.letterLabelRect.minX) < 12, "crop x \(r.cropRect.minX)")
            check(abs(r.cropRect.minY - expectTop) < 12, "crop y \(r.cropRect.minY)")
            guard let bb = bitmapBounds(b) else { check(false, "blank"); return }
            check(bb.maxX - bb.minX > 700, "label fills the width (\(bb))")
            check(bb.maxY - bb.minY > 1050, "label fills the height (\(bb))")
            // The label's top banner ends up on the right edge after a clockwise turn.
            check(blackFraction(b, rows: 300...900, cols: 720...760) > 0.99, "banner on the right edge")
            check(blackFraction(b, rows: 300...900, cols: 40...60) < 0.5, "left edge is not the banner")
        }

        test("manual crop, rotation and no-crop options are honoured") {
            let src = try LabelSource.load(url: tmp.appendingPathComponent("label-letter.pdf"), page: 1)
            var o = RasterOptions()
            o.crop = .none
            o.rotate = .degrees(0)
            let (_, r1) = try Rasterizer.rasterize(src, spec: spec, options: o)
            check(r1.cropRect == CGRect(x: 0, y: 0, width: 612, height: 792) && r1.rotation == 0, "none/0: \(r1)")
            o.crop = .rect(CGRect(x: 90, y: 104, width: 432, height: 288))
            o.rotate = .degrees(270)
            let (b, r2) = try Rasterizer.rasterize(src, spec: spec, options: o)
            check(r2.rotation == 270 && !r2.cropWasAuto, "manual: \(r2)")
            check(blackFraction(b, rows: 300...900, cols: 40...80) > 0.99, "counter-clockwise puts banner on the left")
            o.crop = .rect(CGRect(x: 5000, y: 5000, width: 10, height: 10))
            expectThrows("crop outside page") { _ = try Rasterizer.rasterize(src, spec: spec, options: o) }
            expectThrows("page out of range") { _ = try LabelSource.load(url: tmp.appendingPathComponent("label-letter.pdf"), page: 2) }
        }

        test("landscape PNG is rotated without cropping") {
            let src = try LabelSource.load(url: tmp.appendingPathComponent("label-landscape.png"), page: 1)
            check(src.kind == "image" && src.size == CGSize(width: 1200, height: 800), "png size")
            let (b, r) = try Rasterizer.rasterize(src, spec: spec, options: RasterOptions())
            check(!r.cropWasAuto && r.rotation == 90, "rotate only: \(r)")
            check(blackFraction(b, rows: 300...900, cols: 730...770) > 0.99, "banner on the right edge")
        }

        test("preview PNG matches the bitmap") {
            var b = MonoBitmap(width: 16, height: 4)
            b.setBlack(x: 3, y: 2)
            let url = tmp.appendingPathComponent("p.png")
            try PreviewWriter.writePNG(b, to: url)
            let src = try LabelSource.load(url: url, page: 1)
            let gray = try Rasterizer.renderGray(width: 16, height: 4) { ctx in src.draw(ctx) }
            check(gray[2 * 16 + 3] == 0 && gray[0] == 255, "dot survives PNG round trip")
        }

        test("command line parsing") {
            guard case .print(let o) = try CLI.parse(["label.pdf"]) else { check(false, "shorthand"); return }
            check(o.input == "label.pdf" && o.spec.copies == 1 && o.prefix == "A42BT" && o.waitSeconds == 30 && !o.raw, "defaults")
            guard case .print(let o2) = try CLI.parse(["print", "job.bin", "--dry-run", "--size", "100x150mm", "--rotate", "270",
                                                       "--crop", "10,20,300,400", "--copies", "2", "--gap", "3"]) else { check(false, "print"); return }
            check(o2.raw && o2.dryRun && o2.spec.copies == 2 && o2.spec.gapMM == 3, "flags")
            check(o2.raster.rotate == .degrees(270) && o2.raster.crop == .rect(CGRect(x: 10, y: 20, width: 300, height: 400)), "layout flags")
            guard case .scan(let s) = try CLI.parse(["scan", "--prefix", "", "--wait-sec", "3"]) else { check(false, "scan"); return }
            check(s.prefix == "" && s.waitSeconds == 3, "scan options")
            guard case .check(let c) = try CLI.parse(["check", "--identifier", "00000000-0000-0000-0000-000000000001"]) else { check(false, "check"); return }
            check(c.identifier == UUID(uuidString: "00000000-0000-0000-0000-000000000001") && c.waitSeconds == 30, "check options")
            let help = try CLI.parse([]), version = try CLI.parse(["--version"])
            check(help == .help && version == .version, "help/version")
            expectThrows("bad rotate") { _ = try CLI.parse(["a.pdf", "--rotate", "45"]) }
            expectThrows("missing file") { _ = try CLI.parse(["print", "--dry-run"]) }
            expectThrows("unknown flag") { _ = try CLI.parse(["a.pdf", "--bogus"]) }
            expectThrows("too wide") { _ = try CLI.parse(["a.pdf", "--size", "120x150"]) }
            expectThrows("copies 0") { _ = try CLI.parse(["a.pdf", "--copies", "0"]) }
        }

        print("\(passes) checks passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
