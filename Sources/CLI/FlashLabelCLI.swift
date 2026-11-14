import Foundation

@main
struct FlashLabelCLI {
    static func main() {
        let argv = Array(CommandLine.arguments.dropFirst())
        do {
            switch try CLI.parse(argv) {
            case .help:
                print(CLI.usage)
            case .version:
                print("flashlabel \(flashlabelVersion)")
            case .scan(let o):
                try runScan(o)
            case .check(let o):
                let link = BLEPrinterLink(verbose: o.verbose, log: say)
                let r = try link.check(prefix: o.prefix, identifier: o.identifier, waitSeconds: o.waitSeconds)
                say("\(r.printerName) is reachable and ready to receive a job.")
            case .print(let o):
                try runPrint(o)
            }
        } catch let e as FlashLabelError {
            FileHandle.standardError.write(Data("flashlabel: \(e.description)\n".utf8))
            if case .usage = e { FileHandle.standardError.write(Data("Run flashlabel --help for usage.\n".utf8)) }
            exit(e.exitCode)
        } catch {
            FileHandle.standardError.write(Data("flashlabel: \(error.localizedDescription)\n".utf8))
            exit(2)
        }
    }

    static func say(_ s: String) {
        print(s)
        fflush(stdout)
    }

    static func runScan(_ o: ScanOptions) throws {
        say("Scanning \(fmt(o.waitSeconds)) s for printers\(o.prefix.isEmpty ? "" : " named \(o.prefix)*")...")
        let link = BLEPrinterLink(verbose: false, log: say)
        let found = try link.scan(prefix: o.prefix, seconds: o.waitSeconds)
        if found.isEmpty {
            say("None found. Turn the printer on, close other apps connected to it, and try again.")
            exit(FlashLabelError.printerNotFound("").exitCode)
        }
        for p in found { say("\(p.name)  RSSI \(p.rssi)  identifier \(p.identifier.uuidString)") }
    }

    static func runPrint(_ o: PrintOptions) throws {
        let built = try JobBuilder.build(o)
        say("Job: \(built.summary)")
        if let path = o.preview {
            guard let b = built.bitmap else { throw FlashLabelError.input("no mode-0 BITMAP found to preview in \(o.input)") }
            try PreviewWriter.writePNG(b, to: URL(fileURLWithPath: path))
            say("Preview: \(path)")
        }
        if let path = o.outTSPL {
            do { try built.job.write(to: URL(fileURLWithPath: path)) } catch {
                throw FlashLabelError.input("cannot write \(path): \(error.localizedDescription)")
            }
            say("TSPL job: \(path)")
        }
        if o.dryRun {
            say("Dry run: nothing sent.")
            return
        }
        let link = BLEPrinterLink(verbose: o.verbose, log: say)
        let r = try link.send(job: built.job, prefix: o.prefix, identifier: o.identifier,
                              waitSeconds: o.waitSeconds, timeout: o.timeout)
        say(String(format: "Sent %d bytes to %@ in %d packets, %.1f s (%.1f KB/s).", r.bytes, r.printerName, r.packets,
                   r.seconds, Double(r.bytes) / max(r.seconds, 0.001) / 1024))
        if r.bufferDrained {
            say("The Bluetooth module returned every credit, so the whole job reached the printer.")
        } else {
            say("Warning: not every credit came back before the link closed; the end of the job may not have reached the printer.")
        }
        say("The A42BT does not report paper feed over Bluetooth. Check the printed label.")
    }
}
