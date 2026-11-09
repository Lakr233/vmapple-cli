import Crypto
import Foundation

/// Uploads iBSS to OpenAVB's DFU mode.
public enum DFU {
    private static let blockSize = 0x800
    private static let suffix: [UInt8] = [
        0xff, 0xff, 0xff, 0xff, 0xac, 0x05, 0x00, 0x01, 0x55, 0x46, 0x44, 0x10,
    ]

    /// OpenAVB holds no build's numbers: the host describes the image, and the
    /// ROM measures it against that.
    public struct ImageDescription: Sendable {
        public let compressed: [UInt8]
        public let raw: [UInt8]

        public var bytes: [UInt8] {
            var header = [UInt8]()
            header.appendLittleEndian(UInt32(0x4843_5450))
            header.appendLittleEndian(UInt32(1))
            header.appendLittleEndian(UInt32(0))
            header.appendLittleEndian(UInt32(1))
            header += [UInt8](repeating: 0, count: 8)
            header.appendLittleEndian(UInt32(compressed.count))
            header.appendLittleEndian(UInt32(raw.count))
            header.appendLittleEndian(loadBase)
            header.appendLittleEndian(UInt32(2))
            header += [UInt8](repeating: 0, count: 4)
            header += Array(SHA256.hash(data: compressed))
            header += Array(SHA256.hash(data: raw))
            return header
        }

        var loadBase: UInt64 {
            IBootImage.loadBase(raw: raw)
        }
    }

    public static func withSuffix(_ image: [UInt8]) -> [UInt8] {
        var bytes = image + suffix
        bytes.appendLittleEndian(~CRC32.checksum(bytes))
        return bytes
    }

    public static func send(image: [UInt8], description: ImageDescription, to device: USBDevice) throws {
        try device.controlOut(type: 0x41, request: 0x70, value: 0, index: 0)
        try device.controlOut(type: 0x41, request: 0x71, value: 0, index: 0, data: description.bytes)
        try device.controlOut(type: 0x41, request: 0x72, value: 0, index: 0)

        let bytes = withSuffix(image)
        var block: UInt16 = 0
        for start in stride(from: 0, to: bytes.count, by: blockSize) {
            let end = min(start + blockSize, bytes.count)
            try device.controlOut(type: 0x21, request: 1, value: block, index: 0, data: Array(bytes[start..<end]))
            block += 1
            let status = try device.controlIn(type: 0xa1, request: 3, value: 0, index: 0, length: 6)
            guard status.first == 0 else { throw USBError.malformed("DFU status \(status)") }
        }
        try device.controlOut(type: 0x21, request: 1, value: block, index: 0)
        for _ in 0..<3 {
            _ = try device.controlIn(type: 0xa1, request: 3, value: 0, index: 0, length: 6)
        }
    }
}

enum CRC32 {
    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (0xedb8_8320 & (0 &- (crc & 1)))
            }
        }
        return ~crc
    }
}
