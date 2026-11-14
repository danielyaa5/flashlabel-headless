import CoreBluetooth
import Foundation

struct DiscoveredPrinter {
    let name: String
    let identifier: UUID
    let rssi: Int
}

struct SendResult {
    let printerName: String
    let bytes: Int
    let packets: Int
    let seconds: Double
    let creditsGranted: Int
    let bufferDrained: Bool
}

/// CoreBluetooth link to the printer's FF00 transparent-UART service.
/// All callbacks run on the main queue; the public methods pump the main run loop until done.
final class BLEPrinterLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let service = CBUUID(string: "FF00")
    static let dataIn = CBUUID(string: "FF02")
    static let credit = CBUUID(string: "FF03")
    static let dataOut = CBUUID(string: "FF01")

    private enum Mode { case scan, send }
    private enum Phase { case waitingForBluetooth, scanning, connecting, handshake, sending, draining, done }

    private let log: (String) -> Void
    private let verbose: Bool
    private var central: CBCentralManager!
    private var mode = Mode.scan
    private var phase = Phase.waitingForBluetooth

    // Scan state
    private var prefix = ""
    private var targetIdentifier: UUID?
    private var found: [UUID: DiscoveredPrinter] = [:]

    // Send state
    private var peripheral: CBPeripheral?
    private var dataChar: CBCharacteristic?
    private var pendingNotify = 0
    private var gate = CreditGate()
    private var packets = Packetizer(Data())
    private var packetSize = 0
    private var packetCount = 0
    private var sendStart = Date()
    private var lastProgress = Date()
    private var sendEnd = Date()
    private var handshakeOnly = false
    private var failure: FlashLabelError?
    private var result: SendResult?

    init(verbose: Bool, log: @escaping (String) -> Void) {
        self.verbose = verbose
        self.log = log
        super.init()
    }

    // MARK: Public API

    func scan(prefix: String, seconds: Double) throws -> [DiscoveredPrinter] {
        mode = .scan
        self.prefix = prefix
        start()
        let deadline = Date().addingTimeInterval(seconds + 5)
        var scanDeadline: Date?
        while Date() < deadline, failure == nil {
            if phase == .scanning, scanDeadline == nil { scanDeadline = Date().addingTimeInterval(seconds) }
            if let d = scanDeadline, Date() >= d { break }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        central.stopScan()
        if let f = failure { throw f }
        if scanDeadline == nil { throw FlashLabelError.bluetooth("Bluetooth did not become available") }
        return found.values.sorted { $0.rssi > $1.rssi }
    }

    /// Connects and completes the FF03 handshake, then disconnects without sending anything.
    func check(prefix: String, identifier: UUID?, waitSeconds: Double) throws -> SendResult {
        handshakeOnly = true
        return try send(job: Data(), prefix: prefix, identifier: identifier, waitSeconds: waitSeconds, timeout: 30)
    }

    func send(job: Data, prefix: String, identifier: UUID?, waitSeconds: Double, timeout: Double) throws -> SendResult {
        mode = .send
        self.prefix = prefix
        targetIdentifier = identifier
        // A leading CRLF ends any partial command line left in the printer's parser.
        packets = Packetizer(Data("\r\n".utf8) + job)
        start()
        let hardDeadline = Date().addingTimeInterval(waitSeconds + timeout)
        var scanStarted: Date?
        while phase != .done {
            let now = Date()
            if phase == .scanning, scanStarted == nil { scanStarted = now }
            if let s = scanStarted, phase == .scanning, now.timeIntervalSince(s) > waitSeconds {
                fail(.printerNotFound("no advertising printer matching \(describeTarget()) within \(fmt(waitSeconds)) s; is it on, awake and not connected to another device?"))
            }
            if phase == .waitingForBluetooth, now.timeIntervalSince(sendStart) > 10, scanStarted == nil, failure == nil {
                fail(.bluetooth("Bluetooth did not become available (state \(central.state.rawValue))"))
            }
            if phase == .sending, now.timeIntervalSince(lastProgress) > 10 {
                fail(.transfer("credit stall: no flow-control credit for 10 s after \(packets.offset) of \(packets.data.count) bytes. A partial job may be buffered; power-cycle the printer before retrying."))
            }
            if phase == .draining, now.timeIntervalSince(sendEnd) > 10 {
                finishSend(drained: false)
            }
            if now > hardDeadline, phase != .done {
                fail(.timeout("timed out in phase \(phase) after sending \(packets.offset) of \(packets.data.count) bytes"))
            }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        if let f = failure { throw f }
        guard let r = result else { throw FlashLabelError.transfer("send ended without a result") }
        return r
    }

    // MARK: Internals

    private func start() {
        sendStart = Date()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    private func describeTarget() -> String {
        if let id = targetIdentifier { return "identifier \(id.uuidString)" }
        return prefix.isEmpty ? "any name" : "name prefix \"\(prefix)\""
    }

    private func debug(_ s: String) { if verbose { log(s) } }

    private func fail(_ e: FlashLabelError) {
        guard phase != .done else { return }
        failure = e
        phase = .done
    }

    private func matches(_ p: CBPeripheral, name: String) -> Bool {
        if let id = targetIdentifier { return p.identifier == id }
        return prefix.isEmpty ? !name.isEmpty : name.hasPrefix(prefix)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            guard phase == .waitingForBluetooth else { return }
            phase = .scanning
            c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            debug("scanning for \(describeTarget())")
        case .unauthorized:
            fail(.bluetooth("Bluetooth permission denied. Allow your terminal app in System Settings > Privacy & Security > Bluetooth."))
        case .poweredOff:
            fail(.bluetooth("Bluetooth is turned off"))
        case .unsupported:
            fail(.bluetooth("Bluetooth LE is not supported on this Mac"))
        default:
            break
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        let name = p.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        guard matches(p, name: name) else { return }
        if mode == .scan {
            found[p.identifier] = DiscoveredPrinter(name: name, identifier: p.identifier, rssi: rssi.intValue)
            return
        }
        guard phase == .scanning else { return }
        c.stopScan()
        phase = .connecting
        peripheral = p
        p.delegate = self
        log("Found \(name.isEmpty ? "printer" : name) (RSSI \(rssi)); connecting")
        c.connect(p)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self = self, self.phase == .connecting || self.phase == .handshake else { return }
            self.fail(.handshake("connected printer never completed the FF03 credit handshake; nothing was sent"))
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        debug("connected; discovering FF00")
        p.discoverServices([BLEPrinterLink.service])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        fail(.printerNotFound("connection failed: \(error?.localizedDescription ?? "unknown error")"))
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        switch phase {
        case .done:
            return
        case .draining:
            finishSend(drained: gate.fullyReturned)
        case .sending:
            fail(.transfer("printer disconnected after \(packets.offset) of \(packets.data.count) bytes. Power-cycle it before retrying."))
        default:
            fail(.handshake("printer disconnected before printing started; nothing was sent"))
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = p.services?.first(where: { $0.uuid == BLEPrinterLink.service }) else {
            fail(.handshake("printer does not expose BLE service FF00; nothing was sent"))
            return
        }
        p.discoverCharacteristics(nil, for: svc)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        let chars = s.characteristics ?? []
        dataChar = chars.first { $0.uuid == BLEPrinterLink.dataIn }
        guard dataChar != nil, chars.contains(where: { $0.uuid == BLEPrinterLink.credit }) else {
            fail(.handshake("service FF00 is missing FF02/FF03; nothing was sent"))
            return
        }
        phase = .handshake
        for c in chars where c.properties.contains(.notify) || c.properties.contains(.indicate) {
            pendingNotify += 1
            p.setNotifyValue(true, for: c)
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        if let e = error { debug("notify \(c.uuid.uuidString) error: \(e.localizedDescription)") }
        pendingNotify -= 1
        checkHandshake()
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        let bytes = [UInt8](c.value ?? Data())
        guard c.uuid == BLEPrinterLink.credit else {
            debug("RX \(c.uuid.uuidString): \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
            return
        }
        let n = gate.apply(bytes)
        if case .unknown(let raw) = n { debug("FF03 unknown: \(raw)") }
        switch phase {
        case .handshake: checkHandshake()
        case .sending: lastProgress = Date(); pump()
        case .draining: if gate.fullyReturned { finishSend(drained: true) }
        default: break
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        if phase == .sending { pump() }
    }

    private func checkHandshake() {
        guard phase == .handshake, pendingNotify <= 0, gate.handshakeComplete, let p = peripheral else { return }
        packetSize = min(gate.payloadSize, p.maximumWriteValueLength(for: .withoutResponse))
        guard packetSize > 0 else { fail(.handshake("invalid payload size")); return }
        if handshakeOnly {
            log("Handshake OK: \(gate.credits) credits, \(packetSize)-byte packets; nothing sent")
            result = SendResult(printerName: p.name ?? "printer", bytes: 0, packets: 0, seconds: 0,
                                creditsGranted: gate.granted, bufferDrained: true)
            phase = .done
            return
        }
        log("Handshake OK: \(gate.credits) credits, \(packetSize)-byte packets; sending \(packets.data.count) bytes")
        phase = .sending
        sendStart = Date()
        lastProgress = Date()
        pump()
    }

    private func pump() {
        guard phase == .sending, let p = peripheral, let ch = dataChar else { return }
        while !packets.isFinished, p.canSendWriteWithoutResponse, gate.credits > 0 {
            guard gate.takeCredit(), let chunk = packets.next(maxLength: packetSize) else { break }
            p.writeValue(chunk, for: ch, type: .withoutResponse)
            packetCount += 1
            if packetCount % 100 == 0 {
                debug(String(format: "sent %d/%d bytes (%.0f%%)", packets.offset, packets.data.count,
                             Double(packets.offset) * 100 / Double(packets.data.count)))
            }
        }
        if packets.isFinished {
            sendEnd = Date()
            phase = .draining
            if gate.fullyReturned { finishSend(drained: true) }
        }
    }

    private func finishSend(drained: Bool) {
        guard phase != .done else { return }
        result = SendResult(printerName: peripheral?.name ?? "printer", bytes: packets.data.count, packets: packetCount,
                            seconds: sendEnd.timeIntervalSince(sendStart), creditsGranted: gate.granted,
                            bufferDrained: drained)
        phase = .done
    }
}
