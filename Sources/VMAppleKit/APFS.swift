import Foundation

public enum APFSError: Error, CustomStringConvertible {
    case malformed(String)
    case notFound(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .malformed(let what): "malformed APFS: \(what)"
        case .notFound(let what): "not on the disk: \(what)"
        case .unsupported(let what): "unsupported APFS: \(what)"
        }
    }
}

// MARK: - Disk

/// Random reads from a raw disk image.
final class DiskImage {
    private let handle: FileHandle

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
    }

    deinit {
        try? handle.close()
    }

    func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw APFSError.malformed("short read at \(offset)") }
        return Array(data)
    }
}

extension Array where Element == UInt8 {
    func le<T: FixedWidthInteger>(_ offset: Int, _: T.Type = T.self) -> T {
        (0..<MemoryLayout<T>.size).reduce(T.zero) { $0 | T(self[offset + $1]) << ($1 * 8) }
    }
}

// MARK: - GPT

enum GPT {
    static let apfsType: [UInt8] = [
        0xef, 0x57, 0x34, 0x7c, 0x00, 0x00, 0xaa, 0x11, 0xaa, 0x11, 0x00, 0x30, 0x65, 0x43, 0xec, 0xac,
    ]

    /// Byte ranges of the APFS partitions.
    static func apfsPartitions(_ disk: DiskImage) throws -> [Range<UInt64>] {
        for sector in [UInt64(512), 4096] {
            let header = try disk.read(at: sector, count: 92)
            guard Array(header[0..<8]) == Array("EFI PART".utf8) else { continue }
            let entries: UInt64 = header.le(72)
            let count = Int(header.le(80, UInt32.self))
            let size = Int(header.le(84, UInt32.self))
            guard count <= 1024, (128...4096).contains(size) else { throw APFSError.malformed("GPT entries") }
            let table = try disk.read(at: entries * sector, count: count * size)
            return (0..<count).compactMap { index in
                let entry = Array(table[(index * size)..<((index + 1) * size)])
                guard Array(entry[0..<16]) == apfsType else { return nil }
                let first: UInt64 = entry.le(32)
                let last: UInt64 = entry.le(40)
                return (first * sector)..<((last + 1) * sector)
            }
        }
        throw APFSError.notFound("a GPT")
    }
}

// MARK: - Container

/// An APFS container, read at its latest checkpoint.
final class APFSContainer {
    let disk: DiskImage
    let base: UInt64
    let blockSize: Int
    let xid: UInt64
    private let omapTree: UInt64
    private let volumeIDs: [UInt64]

    init(disk: DiskImage, base: UInt64) throws {
        self.disk = disk
        self.base = base
        let first = try disk.read(at: base, count: 4096)
        guard first.le(32, UInt32.self) == 0x4253_584e else { throw APFSError.malformed("no NXSB at \(base)") }
        blockSize = Int(first.le(36, UInt32.self))
        guard [4096, 8192, 16384, 32768, 65536].contains(blockSize) else {
            throw APFSError.malformed("block size \(blockSize)")
        }
        var latest = try disk.read(at: base, count: blockSize)
        let descriptorBlocks: UInt32 = latest.le(104)
        let descriptorBase: UInt64 = latest.le(112)
        if descriptorBlocks & 0x8000_0000 == 0 {
            for index in 0..<UInt64(descriptorBlocks) {
                let block = try disk.read(at: base + (descriptorBase + index) * UInt64(blockSize), count: blockSize)
                guard block.le(24, UInt32.self) & 0xffff == 1, block.le(32, UInt32.self) == 0x4253_584e,
                      Self.checksum(block) == block.le(0, UInt64.self),
                      block.le(16, UInt64.self) > latest.le(16, UInt64.self) else { continue }
                latest = block
            }
        }
        xid = latest.le(16)
        let omap = try disk.read(at: base + latest.le(160, UInt64.self) * UInt64(blockSize), count: blockSize)
        omapTree = omap.le(48)
        let maximum = min(Int(latest.le(180, UInt32.self)), 100)
        volumeIDs = (0..<maximum).map { latest.le(184 + $0 * 8, UInt64.self) }.filter { $0 != 0 }
    }

    /// Fletcher-64 over everything after the checksum field.
    static func checksum(_ block: [UInt8]) -> UInt64 {
        let modulus: UInt64 = 0xffff_ffff
        var low: UInt64 = 0
        var high: UInt64 = 0
        for offset in stride(from: 8, to: block.count, by: 4) {
            low = (low + UInt64(block.le(offset, UInt32.self))) % modulus
            high = (high + low) % modulus
        }
        let check0 = modulus - ((low + high) % modulus)
        let check1 = modulus - ((low + check0) % modulus)
        return check1 << 32 | check0
    }

    func block(_ address: UInt64) throws -> [UInt8] {
        try disk.read(at: base + address * UInt64(blockSize), count: blockSize)
    }

    func volumes(role: UInt16) throws -> [APFSVolume] {
        try volumeIDs.compactMap { oid in
            let superblock = try block(try resolve(oid, in: omapTree))
            guard superblock.le(964, UInt16.self) == role else { return nil }
            return try APFSVolume(container: self, superblock: superblock)
        }
    }

    /// The block of a virtual object: the newest mapping at or before this checkpoint.
    func resolve(_ oid: UInt64, in tree: UInt64) throws -> UInt64 {
        var node = try BTreeNode(try block(tree))
        while true {
            var chosen: Int?
            for index in 0..<node.count {
                let key = node.key(index, fixedSize: 16)
                let keyID: UInt64 = node.data.le(key.lowerBound)
                let keyXID: UInt64 = node.data.le(key.lowerBound + 8)
                guard (keyID, keyXID) <= (oid, xid) else { break }
                chosen = index
            }
            guard let chosen else { throw APFSError.notFound("object \(oid)") }
            if node.isLeaf {
                let key = node.key(chosen, fixedSize: 16)
                let value = node.value(chosen, fixedSize: 16)
                guard node.data.le(key.lowerBound, UInt64.self) == oid,
                      node.data.le(value.lowerBound, UInt32.self) & 1 == 0 else {
                    throw APFSError.notFound("object \(oid)")
                }
                return node.data.le(value.lowerBound + 8)
            }
            node = try BTreeNode(try block(node.data.le(node.value(chosen, fixedSize: 8).lowerBound)))
        }
    }
}

// MARK: - B-tree node

struct BTreeNode {
    let data: [UInt8]
    let isLeaf: Bool
    let count: Int
    private let fixed: Bool
    private let table: Int
    private let keys: Int
    private let valuesEnd: Int

    init(_ data: [UInt8]) throws {
        self.data = data
        let flags: UInt16 = data.le(32)
        isLeaf = flags & 2 != 0
        fixed = flags & 4 != 0
        count = Int(data.le(36, UInt32.self))
        table = 56 + Int(data.le(40, UInt16.self))
        keys = table + Int(data.le(42, UInt16.self))
        // A root node ends with a 40 byte btree_info_phys_t.
        valuesEnd = data.count - (flags & 1 != 0 ? 40 : 0)
        guard data.le(24, UInt32.self) & 0xffff == 2 || data.le(24, UInt32.self) & 0xffff == 3,
              keys <= valuesEnd, table + count * (fixed ? 4 : 8) <= keys else {
            throw APFSError.malformed("B-tree node")
        }
    }

    func key(_ index: Int, fixedSize: Int = 0) -> Range<Int> {
        let entry = table + index * (fixed ? 4 : 8)
        let start = keys + Int(data.le(entry, UInt16.self))
        return start..<(start + (fixed ? fixedSize : Int(data.le(entry + 2, UInt16.self))))
    }

    func value(_ index: Int, fixedSize: Int = 0) -> Range<Int> {
        let entry = table + index * (fixed ? 4 : 8)
        let start = valuesEnd - Int(data.le(entry + (fixed ? 2 : 4), UInt16.self))
        return start..<(start + (fixed ? fixedSize : Int(data.le(entry + 6, UInt16.self))))
    }
}

// MARK: - Volume

/// One volume's file system tree, enough to read small unencrypted files.
struct APFSVolume {
    enum RecordType: UInt8 {
        case inode = 3
        case fileExtent = 8
        case directoryRecord = 9
    }

    static let rootDirectory: UInt64 = 2
    static let prebootRole: UInt16 = 0x10

    let container: APFSContainer
    let name: String
    let role: UInt16
    private let encrypted: Bool
    private let hashedNames: Bool
    private let omapTree: UInt64
    private let physicalTree: Bool
    private let rootTree: UInt64

    init(container: APFSContainer, superblock: [UInt8]) throws {
        guard superblock.le(32, UInt32.self) == 0x4253_5041 else { throw APFSError.malformed("no APSB") }
        self.container = container
        let incompatible: UInt64 = superblock.le(56)
        hashedNames = incompatible & (0x1 | 0x8) != 0
        encrypted = superblock.le(264, UInt64.self) & 1 == 0
        omapTree = try container.block(superblock.le(128)).le(48)
        // OBJ_PHYSICAL in the tree type: its nodes are addressed by block.
        physicalTree = superblock.le(116, UInt32.self) & 0x4000_0000 != 0
        let root: UInt64 = superblock.le(136)
        rootTree = physicalTree ? root : try container.resolve(root, in: omapTree)
        name = String(decoding: superblock[704..<960].prefix { $0 != 0 }, as: UTF8.self)
        role = superblock.le(964)
    }

    /// Entries of a directory: name, object ID and whether it is a directory.
    func list(_ directory: UInt64) throws -> [(name: String, id: UInt64, isDirectory: Bool)] {
        try records(directory, .directoryRecord).map { key, value in
            let length = hashedNames ? Int(key.le(8, UInt32.self) & 0x3ff) : Int(key.le(8, UInt16.self))
            let start = hashedNames ? 12 : 10
            let name = String(decoding: key[start..<(start + length)].prefix { $0 != 0 }, as: UTF8.self)
            return (name, value.le(0), value.le(16, UInt16.self) & 0xf == 4)
        }
    }

    func lookup(_ path: [String]) throws -> UInt64 {
        try path.reduce(Self.rootDirectory) { directory, component in
            guard let entry = try list(directory).first(where: { $0.name.lowercased() == component.lowercased() }) else {
                throw APFSError.notFound("\(name)/\(path.joined(separator: "/"))")
            }
            return entry.id
        }
    }

    func contents(_ path: [String], limit: Int = 64 << 20) throws -> [UInt8] {
        let file = try lookup(path)
        guard !encrypted else { throw APFSError.unsupported("\(name) is encrypted") }
        guard let inode = try records(file, .inode).first?.value, inode.count >= 92 else {
            throw APFSError.notFound("inode of \(path.joined(separator: "/"))")
        }
        guard inode.le(68, UInt32.self) & 0x20 == 0 else {
            throw APFSError.unsupported("\(path.joined(separator: "/")) is compressed")
        }
        let stream: UInt64 = inode.le(8)
        let size = min(Self.dataStreamSize(inode) ?? UInt64(limit), UInt64(limit))
        var bytes: [UInt8] = []
        let extents = try records(stream, .fileExtent).sorted { $0.key.le(8, UInt64.self) < $1.key.le(8, UInt64.self) }
        for (key, value) in extents where UInt64(bytes.count) < size {
            guard key.le(8, UInt64.self) == UInt64(bytes.count) else { throw APFSError.malformed("extent gap") }
            let length = Int(value.le(0, UInt64.self) & 0x00ff_ffff_ffff_ffff)
            let address: UInt64 = value.le(8)
            let count = min(length, Int(size) - bytes.count)
            if address == 0 {
                bytes += [UInt8](repeating: 0, count: count)
            } else {
                bytes += try container.disk.read(at: container.base + address * UInt64(container.blockSize), count: count)
            }
        }
        return Array(bytes.prefix(Int(size)))
    }

    /// The size from the inode's `INO_EXT_TYPE_DSTREAM` extended field.
    static func dataStreamSize(_ inode: [UInt8]) -> UInt64? {
        guard inode.count >= 96 else { return nil }
        let fields = Int(inode.le(92, UInt16.self))
        var data = 96 + fields * 4
        for index in 0..<fields {
            let header = 96 + index * 4
            guard header + 4 <= inode.count else { return nil }
            let size = Int(inode.le(header + 2, UInt16.self))
            if inode[header] == 8, data + 8 <= inode.count {
                return inode.le(data)
            }
            data += (size + 7) & ~7
        }
        return nil
    }

    /// Every record of one object and type, from the leaves whose key range can hold them.
    private func records(_ object: UInt64, _ type: RecordType) throws -> [(key: [UInt8], value: [UInt8])] {
        let target = (object, type.rawValue)
        func header(_ node: BTreeNode, _ index: Int) -> (UInt64, UInt8) {
            let value: UInt64 = node.data.le(node.key(index).lowerBound)
            return (value & 0x0fff_ffff_ffff_ffff, UInt8(value >> 60))
        }
        var found: [(key: [UInt8], value: [UInt8])] = []
        func visit(_ address: UInt64, depth: Int) throws {
            guard depth < 16 else { throw APFSError.malformed("B-tree depth") }
            let node = try BTreeNode(try container.block(address))
            for index in 0..<node.count {
                let key = header(node, index)
                if node.isLeaf {
                    if key == target {
                        found.append((Array(node.data[node.key(index)]), Array(node.data[node.value(index)])))
                    }
                    continue
                }
                guard key <= target else { break }
                if index + 1 < node.count, header(node, index + 1) < target { continue }
                let child: UInt64 = node.data.le(node.value(index).lowerBound)
                try visit(physicalTree ? child : try container.resolve(child, in: omapTree), depth: depth + 1)
            }
        }
        try visit(rootTree, depth: 0)
        return found
    }
}

// MARK: - Preboot

/// What the Preboot volume says about each installed system: its version and
/// the iBoot that boots it.
public struct PrebootSystem: Sendable {
    public let version: String?
    public let build: String?
    public let iBoots: [[UInt8]]

    /// Where each of its iBoots hands off to the kernel.
    public func handoffAddresses() throws -> [UInt64] {
        var addresses: [UInt64] = []
        for img4 in iBoots {
            let payload = try IMG4.payload(im4p: try IMG4.im4p(img4: img4))
            let raw = payload.starts(with: Array("bvx".utf8)) ? try LZFSE.decode(payload) : payload
            for address in IBootImage.handoffAddresses(raw: raw) where !addresses.contains(address) {
                addresses.append(address)
            }
        }
        return addresses
    }

    public static func read(disk url: URL) throws -> [PrebootSystem] {
        let disk = try DiskImage(url: url)
        var systems: [PrebootSystem] = []
        for partition in try GPT.apfsPartitions(disk) {
            let container = try APFSContainer(disk: disk, base: partition.lowerBound)
            for volume in try container.volumes(role: APFSVolume.prebootRole) {
                for group in try volume.list(APFSVolume.rootDirectory) where group.isDirectory && UUID(uuidString: group.name) != nil {
                    let boot = [group.name, "boot"]
                    guard let entries = try? volume.list(try volume.lookup(boot)) else { continue }
                    // `boot/active` names the boot objects in use; an update can leave others.
                    let active = (try? volume.contents(boot + ["active"])).map {
                        String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    let directories = entries.filter(\.isDirectory).map(\.name)
                    let chosen = directories.filter { $0.caseInsensitiveCompare(active ?? "") == .orderedSame }
                    let iBoots = (chosen.isEmpty ? directories : chosen).compactMap { name in
                        try? volume.contents(boot + [name, "usr", "standalone", "firmware", "iBoot.img4"])
                    }
                    guard !iBoots.isEmpty else { continue }
                    let info = [["cryptex1", "current"], ["restore"], ["System", "Library", "CoreServices"]].lazy.compactMap {
                        (try? volume.contents([group.name] + $0 + ["SystemVersion.plist"])).flatMap {
                            try? PropertyListSerialization.propertyList(from: Data($0), format: nil) as? [String: Any]
                        }
                    }.first
                    systems.append(PrebootSystem(
                        version: info?["ProductVersion"] as? String,
                        build: info?["ProductBuildVersion"] as? String,
                        iBoots: iBoots
                    ))
                }
            }
        }
        return systems
    }
}
