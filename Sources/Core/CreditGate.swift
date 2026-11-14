import Foundation

/// Flow control used by the A42BT's BLE module on service FF00.
///
/// The module notifies on FF03:
///   [0x01, n]          grant n more packet credits
///   [0x02, lo, hi]     maximum payload per packet (little endian)
/// Each writeWithoutResponse packet on FF02 consumes one credit. Writing without a credit
/// lets the module drop data silently, which corrupts a BITMAP and nothing prints.
struct CreditGate {
    enum Notification: Equatable {
        case grant(Int)
        case payloadSize(Int)
        case unknown([UInt8])
    }

    private(set) var credits = 0
    private(set) var payloadSize = 0
    private(set) var granted = 0
    private(set) var consumed = 0
    private(set) var initialCredits = 0
    private var sawGrant = false

    static func parse(_ bytes: [UInt8]) -> Notification {
        if bytes.count == 2, bytes[0] == 0x01 { return .grant(Int(bytes[1])) }
        if bytes.count == 3, bytes[0] == 0x02 { return .payloadSize(Int(bytes[1]) | Int(bytes[2]) << 8) }
        return .unknown(bytes)
    }

    @discardableResult
    mutating func apply(_ bytes: [UInt8]) -> Notification {
        let n = CreditGate.parse(bytes)
        switch n {
        case .grant(let c):
            if !sawGrant { initialCredits = c }
            sawGrant = true
            credits += c
            granted += c
        case .payloadSize(let s):
            payloadSize = s
        case .unknown:
            break
        }
        return n
    }

    /// The module has announced both its starting credits and its payload size.
    var handshakeComplete: Bool { sawGrant && payloadSize > 0 }

    /// True once every credit spent has been handed back, i.e. the module's buffer has drained.
    var fullyReturned: Bool { sawGrant && credits >= initialCredits }

    mutating func takeCredit() -> Bool {
        guard credits > 0 else { return false }
        credits -= 1
        consumed += 1
        return true
    }
}

/// Splits a job into packets no larger than the negotiated payload.
struct Packetizer {
    let data: Data
    private(set) var offset = 0

    init(_ data: Data) { self.data = data }

    var isFinished: Bool { offset >= data.count }

    mutating func next(maxLength: Int) -> Data? {
        guard !isFinished, maxLength > 0 else { return nil }
        let n = min(maxLength, data.count - offset)
        let start = data.startIndex + offset
        offset += n
        return data.subdata(in: start..<(start + n))
    }
}
