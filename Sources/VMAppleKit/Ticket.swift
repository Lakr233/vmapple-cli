import CTicket
import Crypto
import Foundation

public enum TicketError: Error, CustomStringConvertible {
    case refused(String)

    public var description: String {
        switch self {
        case .refused(let what): "Apple's signing server refused the \(what) request"
        }
    }
}

/// What a boot stage reports, and a ticket has to name.
public struct DeviceNonces: Equatable, Sendable {
    public let ap: [UInt8]
    public let sep: [UInt8]

    /// iBoot's product string: ` NONC:... SNON:... CC:0:0`.
    public init?(productString: String) {
        guard let ap = Self.hex(after: "NONC:", in: productString, bytes: 32),
              let sep = Self.hex(after: "SNON:", in: productString, bytes: 20) else { return nil }
        self.ap = ap
        self.sep = sep
    }

    public init(ap: [UInt8], sep: [UInt8]) {
        self.ap = ap
        self.sep = sep
    }

    private static func hex(after key: String, in text: String, bytes: Int) -> [UInt8]? {
        guard let start = text.range(of: key)?.upperBound else { return nil }
        let digits = text[start...].prefix(bytes * 2)
        guard digits.count == bytes * 2 else { return nil }
        var result: [UInt8] = []
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }
}

public enum Ticket {
    public static func request(firmware: Firmware, ecid: UInt64, nonces: DeviceNonces) throws -> [UInt8] {
        try call(firmware: firmware, ecid: ecid, nonces: nonces, policy: nil, nextStage: nil, what: "AP ticket")
    }

    public static func requestLocalPolicy(
        firmware: Firmware,
        ecid: UInt64,
        nonces: DeviceNonces,
        apTicket: [UInt8]
    ) throws -> [UInt8] {
        try call(
            firmware: firmware,
            ecid: ecid,
            nonces: nonces,
            policy: Array(SHA384.hash(data: IMG4.emptyLocalPolicy)),
            nextStage: Array(SHA384.hash(data: apTicket)),
            what: "local policy ticket"
        )
    }

    private static func call(
        firmware: Firmware,
        ecid: UInt64,
        nonces: DeviceNonces,
        policy: [UInt8]?,
        nextStage: [UInt8]?,
        what: String
    ) throws -> [UInt8] {
        var ticket: UnsafeMutablePointer<UInt8>?
        var size = 0
        let result = firmware.manifest.withUnsafeBytes { manifest in
            vmapple_ticket_request(
                manifest.baseAddress,
                manifest.count,
                ecid,
                nonces.ap,
                nonces.sep,
                policy,
                nextStage,
                &ticket,
                &size
            )
        }
        guard result == 0, let ticket else { throw TicketError.refused(what) }
        defer { free(ticket) }
        return Array(UnsafeBufferPointer(start: ticket, count: size))
    }
}
