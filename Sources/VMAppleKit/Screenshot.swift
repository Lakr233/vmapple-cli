import Foundation

/// QEMU's screen dumps are PPM unless it was built with libpng. This writes the
/// same pixels as a PNG with stored deflate blocks, which needs no zlib.
public enum PNG {
    public static func convert(ppm: [UInt8]) throws -> [UInt8] {
        let (width, height, slice) = try parsePPM(ppm)
        let pixels = Array(slice)
        var raw = [UInt8]()
        raw.reserveCapacity((width * 3 + 1) * height)
        for row in 0..<height {
            raw.append(0)
            raw += pixels[(row * width * 3)..<((row + 1) * width * 3)]
        }
        var header = [UInt8]()
        header.appendBigEndian(UInt32(width))
        header.appendBigEndian(UInt32(height))
        header += [8, 2, 0, 0, 0]
        return [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] +
            chunk("IHDR", header) + chunk("IDAT", zlibStored(raw)) + chunk("IEND", [])
    }

    static func parsePPM(_ bytes: [UInt8]) throws -> (Int, Int, ArraySlice<UInt8>) {
        var fields: [String] = []
        var index = 0
        var current = ""
        while fields.count < 4, index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == UInt8(ascii: "#") {
                while index < bytes.count, bytes[index] != 0x0a { index += 1 }
            } else if byte == 0x20 || byte == 0x0a || byte == 0x09 || byte == 0x0d {
                if !current.isEmpty {
                    fields.append(current)
                    current = ""
                }
            } else {
                current.append(Character(UnicodeScalar(byte)))
            }
        }
        guard fields.count == 4, fields[0] == "P6", let width = Int(fields[1]), let height = Int(fields[2]),
              fields[3] == "255", index + width * height * 3 <= bytes.count else {
            throw QEMUError.refused("unexpected screen dump format")
        }
        return (width, height, bytes[index..<(index + width * height * 3)])
    }

    private static func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        var bytes = [UInt8]()
        bytes.appendBigEndian(UInt32(data.count))
        let body = Array(type.utf8) + data
        bytes += body
        bytes.appendBigEndian(CRC32.checksum(body))
        return bytes
    }

    private static func zlibStored(_ data: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = [0x78, 0x01]
        var offset = 0
        repeat {
            let count = min(65535, data.count - offset)
            let final: UInt8 = offset + count == data.count ? 1 : 0
            bytes.append(final)
            bytes += [UInt8(count & 0xff), UInt8(count >> 8), UInt8(~count & 0xff), UInt8((~count >> 8) & 0xff)]
            bytes += data[offset..<(offset + count)]
            offset += count
        } while offset < data.count
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        bytes.appendBigEndian(b << 16 | a)
        return bytes
    }
}
