import Crypto
import Foundation

/// A virtual Mac published the way Tart, macos-image and mini-control publish
/// one: Virtualization.framework's `config.json`, its auxiliary storage as
/// `nvram.bin`, and the raw disk in compressed chunks.
struct TartImage {
    static let configType = "application/vnd.cirruslabs.tart.config.v1"
    static let nvramType = "application/vnd.cirruslabs.tart.nvram.v1"
    static let lz4DiskType = "application/vnd.cirruslabs.tart.disk.v2"
    static let zstdDiskType = "application/vnd.cirruslabs.tart.disk.v2+zstd"
    static let uncompressedSize = "org.cirruslabs.tart.uncompressed-size"
    static let uncompressedDigest = "org.cirruslabs.tart.uncompressed-content-digest"

    struct DiskLayer: Sendable {
        let blob: OCIDescriptor
        let zstd: Bool
        let offset: UInt64
        let size: UInt64
        let digest: String
    }

    let config: OCIDescriptor
    let nvram: OCIDescriptor
    let disk: [DiskLayer]
    let diskBytes: UInt64

    init(manifest: OCIManifest) throws {
        let configs = manifest.layers.filter { $0.mediaType == Self.configType }
        let nvrams = manifest.layers.filter { $0.mediaType == Self.nvramType }
        guard configs.count == 1, nvrams.count == 1 else {
            throw ImageError("not a Tart image: found \(configs.count) config and \(nvrams.count) NVRAM layers, expected 1 of each")
        }
        config = configs[0]
        nvram = nvrams[0]
        var disk: [DiskLayer] = []
        var offset: UInt64 = 0
        for layer in manifest.layers where layer.mediaType != Self.configType && layer.mediaType != Self.nvramType {
            guard layer.mediaType == Self.lz4DiskType || layer.mediaType == Self.zstdDiskType else {
                throw ImageError("unsupported layer type \(layer.mediaType); expected Tart's zstd or LZ4 disk layers")
            }
            guard let size = layer.annotations?[Self.uncompressedSize].flatMap(UInt64.init), size > 0,
                  let digest = layer.annotations?[Self.uncompressedDigest], layer.size > 0 else {
                throw ImageError("disk layer \(layer.digest) has no uncompressed size and digest")
            }
            disk.append(DiskLayer(
                blob: layer,
                zstd: layer.mediaType == Self.zstdDiskType,
                offset: offset,
                size: size,
                digest: digest
            ))
            let (next, overflow) = offset.addingReportingOverflow(size)
            guard !overflow else { throw ImageError("the disk is too large") }
            offset = next
        }
        guard !disk.isEmpty else { throw ImageError("not a Tart image: no disk layers") }
        self.disk = disk
        diskBytes = offset
    }

    // MARK: - Config and NVRAM

    /// The machine identifier Virtualization.framework gave the guest, which its
    /// boot tickets are signed for.
    static func ecid(config data: Data) throws -> UInt64 {
        guard let config = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImageError("config.json is not a JSON object")
        }
        guard (config["os"] as? String ?? "darwin") == "darwin", (config["arch"] as? String ?? "arm64") == "arm64" else {
            throw ImageError("the image is \(config["os"] ?? "?")/\(config["arch"] ?? "?"), not an arm64 macOS guest")
        }
        guard (config["diskFormat"] as? String ?? "raw") == "raw" else {
            throw ImageError("unsupported disk format \(config["diskFormat"] ?? ""); expected raw")
        }
        let model = try plist(config["hardwareModel"])
        let platform = (model["PlatformVersion"] as? NSNumber)?.intValue
        guard platform == 2 else {
            throw ImageError("unsupported hardware model, platform version \(platform ?? 0); expected VirtualMac2,1")
        }
        guard let ecid = (try plist(config["ecid"])["ECID"] as? NSNumber)?.uint64Value, ecid != 0 else {
            throw ImageError("config.json has no ECID")
        }
        return ecid
    }

    private static func plist(_ value: Any?) throws -> [String: Any] {
        guard let text = value as? String, let data = Data(base64Encoded: text),
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ImageError("config.json lacks a hardware model or machine identifier")
        }
        return plist
    }

    /// Virtualization.framework keeps a 16 KiB header before the auxiliary
    /// storage that QEMU and the boot ROM read from offset 0.
    static func aux(nvram: Data) throws -> Data {
        let header = 0x4000
        guard nvram.count == Int(VirtualMachine.auxBytes),
              nvram.subdata(in: header..<(header + 4)) == Data("HUFA".utf8) else {
            throw ImageError("nvram.bin is not Virtualization.framework auxiliary storage")
        }
        return nvram.subdata(in: header..<nvram.count) + Data(count: header)
    }
}

// MARK: - Pull

public enum ImagePull {
    /// Downloads an image into a new VM directory, ready for `boot`.
    public static func run(
        _ reference: OCIReference,
        to directory: URL,
        jobs: Int,
        log: @escaping @Sendable (String) -> Void
    ) throws -> VirtualMachine {
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw ImageError("\(directory.path) already exists; choose another directory")
        }
        let registry = OCIRegistry(reference)
        let (manifest, digest) = try registry.manifest()
        let image = try TartImage(manifest: manifest)
        let compressed = image.disk.reduce(Int64(0)) { $0 + $1.blob.size }
        log("Pulling \(reference.registry)/\(reference.repository)@\(digest): \(gigabytes(image.diskBytes)) disk in \(image.disk.count) layers, \(gigabytes(UInt64(compressed))) to download")

        let ecid = try TartImage.ecid(config: try registry.blob(image.config))
        let staging = directory.deletingLastPathComponent()
            .appending(path: ".\(directory.lastPathComponent).pulling-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try TartImage.aux(nvram: try registry.blob(image.nvram)).write(to: staging.appending(path: "aux.img"))
            let disk = staging.appending(path: "disk.img")
            try DiskAssembly(registry: registry, image: image, disk: disk, scratch: staging, log: log).run(jobs: jobs)

            log("Reading the boot objects from the Preboot volume")
            let systems = try PrebootSystem.read(disk: disk)
            guard systems.count == 1, let system = systems.first else {
                throw ImageError("the Preboot volume has \(systems.count) bootable systems; expected 1")
            }
            let configuration = VirtualMachine.Configuration(
                ecid: ecid,
                diskBytes: image.diskBytes,
                handoffAddresses: try system.handoffAddresses(),
                installed: system.version.map { "\($0) (\(system.build ?? "?"))" },
                image: "\(reference.registry)/\(reference.repository)@\(digest)",
                inlineEncryption: false
            )
            try VirtualMachine(directory: staging, configuration: configuration).save(configuration)
            try FileManager.default.moveItem(at: staging, to: directory)
            return try VirtualMachine.open(at: directory)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1e9)
    }
}

/// Writes the disk layers into one sparse raw image, a few at a time.
private final class DiskAssembly: @unchecked Sendable {
    private let registry: OCIRegistry
    private let image: TartImage
    private let disk: URL
    private let scratch: URL
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var next = 0
    private var done = 0
    private var downloaded: Int64 = 0
    private var failure: Error?

    init(registry: OCIRegistry, image: TartImage, disk: URL, scratch: URL, log: @escaping @Sendable (String) -> Void) {
        self.registry = registry
        self.image = image
        self.disk = disk
        self.scratch = scratch
        self.log = log
    }

    func run(jobs: Int) throws {
        FileManager.default.createFile(atPath: disk.path, contents: nil)
        let handle = try FileHandle(forWritingTo: disk)
        try handle.truncate(atOffset: image.diskBytes)
        try handle.close()
        let descriptor = open(disk.path, O_WRONLY)
        guard descriptor >= 0 else { throw ImageError("cannot open \(disk.path)") }
        defer { close(descriptor) }

        DispatchQueue.concurrentPerform(iterations: max(1, min(jobs, image.disk.count))) { _ in
            while let index = take() {
                do {
                    try pull(image.disk[index], index: index, into: descriptor)
                } catch {
                    lock.withLock { failure = failure ?? error }
                }
            }
        }
        if let failure { throw failure }
    }

    private func take() -> Int? {
        lock.withLock {
            guard failure == nil, next < image.disk.count else { return nil }
            next += 1
            return next - 1
        }
    }

    private func pull(_ layer: TartImage.DiskLayer, index: Int, into descriptor: Int32) throws {
        let blob = scratch.appending(path: "layer-\(index)")
        defer { try? FileManager.default.removeItem(at: blob) }
        for attempt in 1...3 {
            do {
                try registry.download(layer.blob, to: blob)
                break
            } catch where attempt < 3 {
                log("Layer \(index + 1): \(error); trying again")
            }
        }

        var sink = LayerSink(layer: layer, descriptor: descriptor, path: disk.path)
        let input = try FileHandle(forReadingFrom: blob)
        defer { try? input.close() }
        if layer.zstd {
            try Self.unzstd(input) { try sink.write($0) }
        } else {
            try AppleLZ4.decode(input) { try sink.write($0) }
        }
        try sink.finish()

        let (count, total) = lock.withLock {
            done += 1
            downloaded += layer.blob.size
            return (done, downloaded)
        }
        log("Disk layer \(count) of \(image.disk.count), \(ImagePull.gigabytes(UInt64(total))) downloaded")
    }

    /// `zstd` is a host package. A layer may hold several frames.
    private static func unzstd(_ input: FileHandle, output: ([UInt8]) throws -> Void) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["zstd", "-d", "-c", "-q"]
        let pipe = Pipe()
        process.standardInput = input
        process.standardOutput = pipe
        try process.run()
        do {
            while let chunk = try pipe.fileHandleForReading.read(upToCount: 4 << 20), !chunk.isEmpty {
                try output(Array(chunk))
            }
        } catch {
            process.terminate()
            process.waitUntilExit()
            throw error
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ImageError("zstd exited with \(process.terminationStatus)") }
    }
}

/// Checks one layer's decompressed bytes and writes all but the zeros.
private struct LayerSink {
    let layer: TartImage.DiskLayer
    let descriptor: Int32
    let path: String
    private var hash = SHA256()
    private var written: UInt64 = 0

    init(layer: TartImage.DiskLayer, descriptor: Int32, path: String) {
        self.layer = layer
        self.descriptor = descriptor
        self.path = path
    }

    mutating func write(_ bytes: [UInt8]) throws {
        guard written + UInt64(bytes.count) <= layer.size else {
            throw ImageError("disk layer \(layer.blob.digest) decompressed to more than the expected \(layer.size) bytes; pull again or check the image")
        }
        hash.update(data: bytes)
        let run = 1 << 16
        try bytes.withUnsafeBytes { buffer in
            for start in stride(from: 0, to: buffer.count, by: run) {
                let piece = UnsafeRawBufferPointer(rebasing: buffer[start..<min(start + run, buffer.count)])
                guard !Self.isZero(piece) else { continue }
                var done = 0
                while done < piece.count {
                    let count = pwrite(
                        descriptor,
                        piece.baseAddress! + done,
                        piece.count - done,
                        off_t(layer.offset + written + UInt64(start + done))
                    )
                    guard count > 0 else { throw ImageError("cannot write \(path): \(String(cString: strerror(errno)).lowercased())") }
                    done += count
                }
            }
        }
        written += UInt64(bytes.count)
    }

    static func isZero(_ bytes: UnsafeRawBufferPointer) -> Bool {
        var index = 0
        while index + 8 <= bytes.count {
            if bytes.loadUnaligned(fromByteOffset: index, as: UInt64.self) != 0 { return false }
            index += 8
        }
        return bytes[index...].allSatisfy { $0 == 0 }
    }

    func finish() throws {
        let digest = "sha256:" + hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard written == layer.size, digest == layer.digest else {
            throw ImageError("disk layer \(layer.blob.digest) decompressed to \(digest); pull again or check the image")
        }
    }
}
