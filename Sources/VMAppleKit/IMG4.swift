import Foundation

public enum IMG4Error: Error, CustomStringConvertible {
    case malformed(String)

    public var description: String {
        switch self {
        case .malformed(let what): "malformed IMG4 data: \(what)"
        }
    }
}

enum DER {
    static func element(tag: UInt8, _ body: [UInt8]) -> [UInt8] {
        [tag] + length(body.count) + body
    }

    static func length(_ value: Int) -> [UInt8] {
        if value < 0x80 { return [UInt8(value)] }
        var bytes: [UInt8] = []
        var rest = value
        while rest > 0 {
            bytes.insert(UInt8(rest & 0xff), at: 0)
            rest >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    /// The body of the element at `offset`, and where the next one starts.
    static func read(_ bytes: [UInt8], at offset: Int) throws -> (body: Range<Int>, next: Int) {
        guard offset + 2 <= bytes.count else { throw IMG4Error.malformed("truncated element") }
        var position = offset + 2
        var size = Int(bytes[offset + 1])
        if size & 0x80 != 0 {
            let count = size & 0x7f
            guard position + count <= bytes.count else { throw IMG4Error.malformed("truncated length") }
            size = bytes[position..<(position + count)].reduce(0) { $0 << 8 | Int($1) }
            position += count
        }
        guard position + size <= bytes.count else { throw IMG4Error.malformed("element past the end") }
        return (position..<(position + size), position + size)
    }
}

public enum IMG4 {
    /// The tag of an IM4P lives at a fixed place, and the restore's image kinds
    /// differ from the installed ones only in that tag.
    public static func retagged(im4p: [UInt8], tag: String) throws -> [UInt8] {
        let tagBytes = Array(tag.utf8)
        guard tagBytes.count == 4 else { throw IMG4Error.malformed("tag \(tag)") }
        let sequence = try DER.read(im4p, at: 0)
        let name = try DER.read(im4p, at: sequence.body.lowerBound)
        guard Array(im4p[name.body]) == Array("IM4P".utf8) else { throw IMG4Error.malformed("not an IM4P") }
        let oldTag = try DER.read(im4p, at: name.next)
        guard oldTag.body.count == 4 else { throw IMG4Error.malformed("IM4P tag length") }
        var result = im4p
        result.replaceSubrange(oldTag.body, with: tagBytes)
        return result
    }

    /// The IM4P inside an IMG4, which also holds the ticket that signs it.
    public static func im4p(img4: [UInt8]) throws -> [UInt8] {
        let sequence = try DER.read(img4, at: 0)
        let name = try DER.read(img4, at: sequence.body.lowerBound)
        guard Array(img4[name.body]) == Array("IMG4".utf8) else { throw IMG4Error.malformed("not an IMG4") }
        return Array(img4[name.next..<(try DER.read(img4, at: name.next).next)])
    }

    public static func payload(im4p: [UInt8]) throws -> [UInt8] {
        let sequence = try DER.read(im4p, at: 0)
        var offset = sequence.body.lowerBound
        for _ in 0..<3 {
            offset = try DER.read(im4p, at: offset).next
        }
        guard im4p[offset] == 0x04 else { throw IMG4Error.malformed("no IM4P payload") }
        return Array(im4p[try DER.read(im4p, at: offset).body])
    }

    public static func wrap(im4p: [UInt8], ticket: [UInt8]) -> [UInt8] {
        let name = DER.element(tag: 0x16, Array("IMG4".utf8))
        return DER.element(tag: 0x30, name + im4p + DER.element(tag: 0xa0, ticket))
    }

    /// iBEC will not start without a local policy. A restore uses an empty one,
    /// whose ticket is what matters.
    public static let emptyLocalPolicy: [UInt8] =
        DER.element(
            tag: 0x30,
            DER.element(tag: 0x16, Array("IM4P".utf8)) +
                DER.element(tag: 0x16, Array("lpol".utf8)) +
                DER.element(tag: 0x16, Array("1.0".utf8)) +
                DER.element(tag: 0x04, [0])
        )
}
