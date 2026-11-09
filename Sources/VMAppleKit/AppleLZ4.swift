import Foundation

/// Apple's LZ4 stream, which Tart's `disk.v2` layers use: `bv41` blocks of raw
/// LZ4 whose matches may reach 64 KiB back into earlier blocks, `bv4-` stored
/// blocks, and `bv4$` at the end.
enum AppleLZ4 {
    static let window = 1 << 16

    static func decode(_ input: FileHandle, output: ([UInt8]) throws -> Void) throws {
        var history: [UInt8] = []
        func read(_ count: Int) throws -> [UInt8] {
            let data = try input.read(upToCount: count) ?? Data()
            guard data.count == count else { throw ImageError("truncated LZ4 layer") }
            return Array(data)
        }
        while true {
            let magic = try read(4)
            guard magic.starts(with: Array("bv4".utf8)) else { throw ImageError("not an Apple LZ4 block") }
            let block: [UInt8]
            switch magic[3] {
            case UInt8(ascii: "$"):
                return
            case UInt8(ascii: "-"):
                let size = Int(try read(4).le(0, UInt32.self))
                block = try read(size)
            case UInt8(ascii: "1"):
                let sizes = try read(8)
                let decoded = Int(sizes.le(0, UInt32.self))
                block = try decodeBlock(try read(Int(sizes.le(4, UInt32.self))), size: decoded, history: history)
            default:
                throw ImageError("unknown LZ4 block \(String(decoding: magic, as: UTF8.self))")
            }
            try output(block)
            history = Array((history + block).suffix(window))
        }
    }

    /// One LZ4 block, decoded after `history`, which its matches may reach into.
    static func decodeBlock(_ input: [UInt8], size: Int, history: [UInt8]) throws -> [UInt8] {
        var out = history + [UInt8](repeating: 0, count: size)
        let end = out.count
        var position = history.count
        try input.withUnsafeBufferPointer { input in
            try out.withUnsafeMutableBufferPointer { out in
                var index = 0
                func length(_ base: Int) throws -> Int {
                    var total = base
                    guard base == 15 else { return total }
                    while true {
                        guard index < input.count else { throw ImageError("truncated LZ4 length") }
                        let byte = Int(input[index])
                        index += 1
                        total += byte
                        if byte != 255 { return total }
                    }
                }
                while index < input.count {
                    let token = Int(input[index])
                    index += 1
                    let literals = try length(token >> 4)
                    guard index + literals <= input.count, position + literals <= end else {
                        throw ImageError("LZ4 literals past the end")
                    }
                    for offset in 0..<literals {
                        out[position + offset] = input[index + offset]
                    }
                    index += literals
                    position += literals
                    if index == input.count { break }
                    guard index + 2 <= input.count else { throw ImageError("truncated LZ4 match") }
                    let distance = Int(input[index]) | Int(input[index + 1]) << 8
                    index += 2
                    let count = try length(token & 15) + 4
                    guard distance > 0, distance <= position, position + count <= end else {
                        throw ImageError("LZ4 match out of range")
                    }
                    for offset in 0..<count {
                        out[position + offset] = out[position - distance + offset]
                    }
                    position += count
                }
            }
        }
        guard position == end else { throw ImageError("LZ4 block decoded to \(position - history.count) of \(size) bytes") }
        return Array(out[history.count...])
    }
}
