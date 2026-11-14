import CoreGraphics
import Foundation

let flashlabelVersion = "0.1.0"

struct PrintOptions: Equatable {
    var input: String = ""
    var raw = false
    var dryRun = false
    var preview: String?
    var outTSPL: String?
    var spec = LabelSpec()
    var raster = RasterOptions()
    var prefix = "A42BT"
    var identifier: UUID?
    var waitSeconds: Double = 30
    var timeout: Double = 120
    var verbose = false
}

struct ScanOptions: Equatable {
    var prefix = "A42BT"
    var waitSeconds: Double = 8
}

struct CheckOptions: Equatable {
    var prefix = "A42BT"
    var identifier: UUID?
    var waitSeconds: Double = 30
    var verbose = false
}

enum Command: Equatable {
    case help
    case version
    case scan(ScanOptions)
    case check(CheckOptions)
    case print(PrintOptions)
}

enum CLI {
    static let usage = """
    flashlabel \(flashlabelVersion): print 4x6 shipping labels on an Arrvel A42BT over Bluetooth LE

    Usage:
      flashlabel print <file> [options]     Print a PDF, image or raw TSPL .bin (one copy by default)
      flashlabel <file> [options]           Same as print
      flashlabel scan [--prefix P] [--wait-sec N]
                                            List nearby advertising printers
      flashlabel check [--prefix P | --identifier UUID] [--wait-sec N]
                                            Connect and complete the flow-control handshake without printing
      flashlabel --help | --version

    Input and layout:
      --page N               PDF page to print (default 1)
      --rotate MODE          auto | 0 | 90 | 180 | 270, clockwise (default auto)
      --crop MODE            auto | none | x,y,w,h in PDF points or image pixels, from top-left (default auto)
      --threshold N          gray level below which a dot is black, 1-254 (default 128)
      --raw                  Send the file as an already built TSPL job (implied for .bin)

    Label and printer settings:
      --size WxH             Label size in mm (default 100x150)
      --gap MM               Gap between labels in mm (default 2)
      --density N            Print darkness 1-15 (default 8)
      --speed N              Print speed (default 4)
      --copies N             Copies (default 1)

    Connection:
      --prefix P             Bluetooth name prefix to match (default A42BT)
      --identifier UUID      Pick one printer by its CoreBluetooth identifier (see scan)
      --wait-sec N           Seconds to wait for the printer to advertise (default 30; scan default 8)
      --timeout N            Seconds allowed for connect and transfer (default 120)

    Output:
      --dry-run              Build the job without using Bluetooth
      --preview FILE.png     Save the exact dots that will print
      --out-tspl FILE.bin    Save the TSPL job
      -v, --verbose          Show connection and transfer details

    Exit codes: 0 ok, 1 usage, 2 input, 3 printer not found, 4 handshake, 5 transfer, 6 timeout, 7 Bluetooth.
    """

    static func parse(_ argv: [String]) throws -> Command {
        var args = argv
        guard let first = args.first else { return .help }
        switch first {
        case "-h", "--help", "help": return .help
        case "--version", "version": return .version
        case "scan", "--scan":
            args.removeFirst()
            return .scan(try parseScan(args))
        case "check":
            args.removeFirst()
            return .check(try parseCheck(args))
        case "print":
            args.removeFirst()
        default:
            break
        }
        return .print(try parsePrint(args))
    }

    static func parseScan(_ argv: [String]) throws -> ScanOptions {
        var o = ScanOptions()
        var it = argv.makeIterator()
        while let a = it.next() {
            switch a {
            case "--prefix": o.prefix = try value(a, &it)
            case "--wait-sec": o.waitSeconds = try positiveDouble(a, try value(a, &it))
            default: throw FlashLabelError.usage("unknown scan option \(a)")
            }
        }
        return o
    }

    static func parseCheck(_ argv: [String]) throws -> CheckOptions {
        var o = CheckOptions()
        var it = argv.makeIterator()
        while let a = it.next() {
            switch a {
            case "--prefix": o.prefix = try value(a, &it)
            case "--identifier":
                let v = try value(a, &it)
                guard let id = UUID(uuidString: v) else { throw FlashLabelError.usage("--identifier expects a UUID") }
                o.identifier = id
            case "--wait-sec": o.waitSeconds = try positiveDouble(a, try value(a, &it))
            case "-v", "--verbose": o.verbose = true
            default: throw FlashLabelError.usage("unknown check option \(a)")
            }
        }
        return o
    }

    static func parsePrint(_ argv: [String]) throws -> PrintOptions {
        var o = PrintOptions()
        var it = argv.makeIterator()
        while let a = it.next() {
            switch a {
            case "--dry-run": o.dryRun = true
            case "--raw": o.raw = true
            case "-v", "--verbose": o.verbose = true
            case "--preview": o.preview = try value(a, &it)
            case "--out-tspl": o.outTSPL = try value(a, &it)
            case "--page": o.raster.page = try int(a, try value(a, &it), 1...10_000)
            case "--threshold": o.raster.threshold = try int(a, try value(a, &it), 1...254)
            case "--rotate": o.raster.rotate = try parseRotate(try value(a, &it))
            case "--crop": o.raster.crop = try parseCrop(try value(a, &it))
            case "--size":
                let (w, h) = try parseSize(try value(a, &it))
                o.spec.widthMM = w
                o.spec.heightMM = h
            case "--gap": o.spec.gapMM = try double(a, try value(a, &it))
            case "--density": o.spec.density = try int(a, try value(a, &it), 1...15)
            case "--speed": o.spec.speed = try positiveDouble(a, try value(a, &it))
            case "--copies": o.spec.copies = try int(a, try value(a, &it), 1...100)
            case "--prefix": o.prefix = try value(a, &it)
            case "--identifier":
                let v = try value(a, &it)
                guard let id = UUID(uuidString: v) else { throw FlashLabelError.usage("--identifier expects a UUID") }
                o.identifier = id
            case "--wait-sec": o.waitSeconds = try positiveDouble(a, try value(a, &it))
            case "--timeout": o.timeout = try positiveDouble(a, try value(a, &it))
            default:
                if a.hasPrefix("-") { throw FlashLabelError.usage("unknown option \(a)") }
                guard o.input.isEmpty else { throw FlashLabelError.usage("only one input file is allowed") }
                o.input = a
            }
        }
        guard !o.input.isEmpty else { throw FlashLabelError.usage("missing input file") }
        if o.input.lowercased().hasSuffix(".bin") { o.raw = true }
        try o.spec.validate()
        return o
    }

    static func parseRotate(_ s: String) throws -> RotateMode {
        if s == "auto" { return .auto }
        guard let d = Int(s), [0, 90, 180, 270].contains(d) else {
            throw FlashLabelError.usage("--rotate expects auto, 0, 90, 180 or 270")
        }
        return .degrees(d)
    }

    static func parseCrop(_ s: String) throws -> CropMode {
        switch s {
        case "auto": return .auto
        case "none": return .none
        default:
            let parts = s.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 4, let x = parts[0], let y = parts[1], let w = parts[2], let h = parts[3],
                  x >= 0, y >= 0, w > 0, h > 0 else {
                throw FlashLabelError.usage("--crop expects auto, none or x,y,w,h")
            }
            return .rect(CGRect(x: x, y: y, width: w, height: h))
        }
    }

    static func parseSize(_ s: String) throws -> (Double, Double) {
        let parts = s.lowercased().replacingOccurrences(of: "mm", with: "").split(separator: "x")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 else {
            throw FlashLabelError.usage("--size expects WxH in mm, for example 100x150")
        }
        return (w, h)
    }

    private static func value(_ flag: String, _ it: inout IndexingIterator<[String]>) throws -> String {
        guard let v = it.next() else { throw FlashLabelError.usage("\(flag) needs a value") }
        return v
    }

    private static func int(_ flag: String, _ s: String, _ range: ClosedRange<Int>) throws -> Int {
        guard let v = Int(s), range.contains(v) else {
            throw FlashLabelError.usage("\(flag) expects a whole number from \(range.lowerBound) to \(range.upperBound)")
        }
        return v
    }

    private static func double(_ flag: String, _ s: String) throws -> Double {
        guard let v = Double(s), v.isFinite, v >= 0 else { throw FlashLabelError.usage("\(flag) expects a number") }
        return v
    }

    private static func positiveDouble(_ flag: String, _ s: String) throws -> Double {
        let v = try double(flag, s)
        guard v > 0 else { throw FlashLabelError.usage("\(flag) must be greater than 0") }
        return v
    }
}

/// Builds the TSPL job for a print command (no Bluetooth).
enum JobBuilder {
    struct Built {
        let job: Data
        let bitmap: MonoBitmap?
        let summary: String
    }

    static func build(_ o: PrintOptions) throws -> Built {
        let url = URL(fileURLWithPath: o.input)
        if o.raw {
            guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                throw FlashLabelError.input("cannot read TSPL job: \(o.input)")
            }
            let bitmap = TSPL.extractBitmap(from: data)
            var summary = "raw TSPL job, \(data.count) bytes"
            if let b = bitmap { summary += ", bitmap \(b.width)x\(b.height) dots" }
            if let c = TSPL.printCopies(in: data) { summary += ", PRINT \(c)" }
            return Built(job: data, bitmap: bitmap, summary: summary)
        }
        let source = try LabelSource.load(url: url, page: o.raster.page)
        let (bitmap, r) = try Rasterizer.rasterize(source, spec: o.spec, options: o.raster)
        guard bitmap.blackDotCount > 0 else { throw FlashLabelError.input("rendered label is blank; check --page, --crop or --threshold") }
        let job = TSPL.job(spec: o.spec, bitmap: bitmap)
        let c = r.cropRect
        let summary = String(format: "%@ %@x%@, crop %@ (%@,%@ %@x%@), rotate %d, %dx%d dots (%.1f%% black), %d bytes, %d %@",
                             r.sourceKind, fmt(Double(r.sourceSize.width)), fmt(Double(r.sourceSize.height)),
                             r.cropWasAuto ? "auto" : "full/manual", fmt(Double(c.minX)), fmt(Double(c.minY)),
                             fmt(Double(c.width)), fmt(Double(c.height)), r.rotation, bitmap.width, bitmap.height,
                             Double(bitmap.blackDotCount) * 100 / Double(bitmap.width * bitmap.height),
                             job.count, o.spec.copies, o.spec.copies == 1 ? "copy" : "copies")
        return Built(job: job, bitmap: bitmap, summary: summary)
    }
}
