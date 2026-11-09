import Foundation

public enum FirmwareError: Error, CustomStringConvertible {
    case noIdentity(String)
    case missing(String)
    case tool(String)

    public var description: String {
        switch self {
        case .noIdentity(let path): "no vma2 erase identity in \(path)"
        case .missing(let component): "no \(component) in the build manifest"
        case .tool(let message): message
        }
    }
}

/// An extracted IPSW, and the identity that restores a virtual Mac from it.
public struct Firmware: Sendable {
    public let directory: URL
    public let manifest: Data
    public let version: String
    public let build: String
    private let paths: [String: String]
    private let loadedByIBoot: [String]

    public init(directory: URL) throws {
        self.directory = directory
        manifest = try Data(contentsOf: directory.appending(path: "BuildManifest.plist"))
        let plist = try PropertyListSerialization.propertyList(from: manifest, format: nil) as? [String: Any]
        let identities = plist?["BuildIdentities"] as? [[String: Any]] ?? []
        guard let identity = identities.first(where: Self.isVirtualMacErase),
              let components = identity["Manifest"] as? [String: [String: Any]] else {
            throw FirmwareError.noIdentity(directory.path)
        }
        version = plist?["ProductVersion"] as? String ?? "?"
        build = plist?["ProductBuildVersion"] as? String ?? "?"
        var paths: [String: String] = [:]
        var loadedByIBoot: [String] = []
        for (name, component) in components {
            guard let info = component["Info"] as? [String: Any] else { continue }
            if let path = info["Path"] as? String { paths[name] = path }
            if info["IsLoadedByiBoot"] as? Bool == true { loadedByIBoot.append(name) }
        }
        self.paths = paths
        self.loadedByIBoot = loadedByIBoot.sorted()
    }

    static func isVirtualMacErase(_ identity: [String: Any]) -> Bool {
        guard let info = identity["Info"] as? [String: Any],
              let device = info["DeviceClass"] as? String,
              let variant = info["Variant"] as? String else { return false }
        return device.lowercased() == "vma2macosap" && variant.contains("Erase Install") &&
            info["RestoreBehavior"] as? String == "Erase"
    }

    public func load(_ component: String) throws -> [UInt8] {
        guard let path = paths[component] else { throw FirmwareError.missing(component) }
        return Array(try Data(contentsOf: directory.appending(path: path)))
    }

    /// What iBEC is sent with the `firmware` command before the ramdisk.
    public var firmwareComponents: [String] {
        loadedByIBoot
    }

    /// Extracts next to the IPSW, once.
    public static func prepare(ipsw: URL) throws -> Firmware {
        let directory = ipsw.deletingPathExtension()
        if !FileManager.default.fileExists(atPath: directory.appending(path: "BuildManifest.plist").path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Tool.run("unzip", ["-q", "-o", ipsw.path, "-d", directory.path])
        }
        return try Firmware(directory: directory)
    }

    /// `lzfse` is a host package, because OpenAVB wants the digest of the raw image.
    public func iBSSDescription() throws -> DFU.ImageDescription {
        let (compressed, raw) = try decompressed("iBSS")
        return DFU.ImageDescription(compressed: compressed, raw: raw)
    }

    /// Where the kernel handoff runs when `component` boots it.
    public func handoffAddresses(for component: String) throws -> [UInt64] {
        IBootImage.handoffAddresses(raw: try decompressed(component).raw)
    }

    func decompressed(_ component: String) throws -> (compressed: [UInt8], raw: [UInt8]) {
        let payload = try IMG4.payload(im4p: try load(component))
        let scratch = FileManager.default.temporaryDirectory.appending(path: "vmapple-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let compressed = scratch.appending(path: "image.lzfse")
        let raw = scratch.appending(path: "image.raw")
        try Data(payload).write(to: compressed)
        try Tool.run("lzfse", ["-decode", "-i", compressed.path, "-o", raw.path])
        return (payload, Array(try Data(contentsOf: raw)))
    }
}

/// What the host reads out of an iBoot image.
enum IBootImage {
    /// Where iBoot says it links: 0x100 past its banner, which sits at 0x200
    /// up to macOS 26 and at 0x280 from 27.
    static func loadBase(raw: [UInt8]) -> UInt64 {
        let start = stride(from: 0x200, through: 0x400, by: 0x40).first { offset in
            ["iBootStage1 for", "iBootStage2 for", "iBoot for", "iBEC for"].contains { banner in
                let bytes = Array(banner.utf8)
                return offset + bytes.count <= raw.count && Array(raw[offset..<(offset + bytes.count)]) == bytes
            }
        } ?? 0x200
        let field = start + 0x100
        guard field + 8 <= raw.count else { return 0 }
        return raw[field..<(field + 8)].reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }

    /// iBoot leaves every stage through a trampoline with x1 holding the boot
    /// arguments, when it boots a kernel. It runs either from a copy in a 16 KiB
    /// window (0xaca00000 up to macOS 26, 0xe0a00000 in 27) or in place.
    static func handoffAddresses(raw: [UInt8]) -> [UInt64] {
        let trampoline: [UInt8] = [0xdf, 0x4f, 0x03, 0xd5, 0xfd, 0x03, 0x00, 0xaa, 0xfc, 0x03, 0x01, 0xaa]
        var addresses: [UInt64] = [trampolineWindow(raw: raw) ?? 0xaca0_0000]
        var offset = 0
        while offset + trampoline.count <= raw.count {
            if raw[offset] == trampoline[0], Array(raw[offset..<(offset + trampoline.count)]) == trampoline {
                addresses.append(loadBase(raw: raw) + UInt64(offset))
                break
            }
            offset += 4
        }
        return addresses
    }

    /// The base of the trampoline window, read from the function that returns
    /// its bounds: `mov w0, #base; mov w1, #base; mov w2, #0x4000;
    /// movk w2, #(base >> 16), lsl #16`.
    static func trampolineWindow(raw: [UInt8]) -> UInt64? {
        func word(_ index: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(raw[index * 4 + $1]) << ($1 * 8) }
        }
        let movzW2Size: UInt32 = 0x5288_0002
        for index in 2..<max(2, raw.count / 4 - 1) where word(index) == movzW2Size {
            let movk = word(index + 1)
            guard movk & 0xffe0_001f == 0x72a0_0002 else { continue }
            let high = (movk >> 5) & 0xffff
            let movzBase: UInt32 = 0x52a0_0000 | high << 5
            if word(index - 2) == movzBase | 0, word(index - 1) == movzBase | 1 {
                return UInt64(high) << 16
            }
        }
        return nil
    }
}

enum Tool {
    static func run(_ name: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [name] + arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FirmwareError.tool("\(name) exited with \(process.terminationStatus)")
        }
    }
}

public enum Tag {
    /// Restore images share their files with the installed ones and differ in tag.
    static let restoreComponents: [String: String] = [
        "Ap,RestoreCIO": "rcio",
        "Ap,RestoreSecurePageTableMonitor": "rspt",
        "Ap,RestoreTMU": "rtmu",
        "Ap,RestoreTrustedExecutionMonitor": "rtrx",
        "Ap,RestorecL4": "rxcl",
        "RestoreDCP": "rdcp",
        "RestoreDeviceTree": "rdtr",
        "RestoreKernelCache": "rkrn",
        "RestoreLogo": "rlgo",
        "RestoreRamDisk": "rdsk",
        "RestoreSEP": "rsep",
        "RestoreTrustCache": "rtsc",
    ]
}
