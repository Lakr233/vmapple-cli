import Foundation
import Testing

@testable import VMAppleKit

@Suite struct OCIReferenceTests {
    @Test func tagDigestAndDefault() throws {
        let tagged = try OCIReference("ghcr.io/minimillionaire/macos-golden-gate-base:27.2")
        #expect(tagged.registry == "ghcr.io")
        #expect(tagged.repository == "minimillionaire/macos-golden-gate-base")
        #expect(tagged.reference == "27.2")

        let pinned = try OCIReference("ghcr.io/owner/image@sha256:abcd")
        #expect(pinned.repository == "owner/image")
        #expect(pinned.reference == "sha256:abcd")
        #expect(pinned.description == "ghcr.io/owner/image@sha256:abcd")

        let local = try OCIReference("localhost:5000/owner/image")
        #expect(local.registry == "localhost:5000")
        #expect(local.reference == "latest")
    }

    @Test func needsARegistry() {
        #expect(throws: ImageError.self) { try OCIReference("ubuntu:22.04") }
        #expect(throws: ImageError.self) { try OCIReference("owner/image:tag") }
    }

    @Test func bearerChallengeKeepsQuotedCommas() {
        let challenge = OCIRegistry.bearerChallenge(
            #"Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:owner/image:pull,push""#
        )
        #expect(challenge?["realm"] == "https://ghcr.io/token")
        #expect(challenge?["service"] == "ghcr.io")
        #expect(challenge?["scope"] == "repository:owner/image:pull,push")
        #expect(OCIRegistry.bearerChallenge(#"Basic realm="x""#) == nil)
    }
}

@Suite struct TartImageTests {
    private func manifest(_ layers: String) throws -> OCIManifest {
        let json = """
        {"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
         "config": {"mediaType": "application/vnd.oci.image.config.v1+json", "digest": "sha256:c", "size": 1},
         "layers": [\(layers)]}
        """
        return try JSONDecoder().decode(OCIManifest.self, from: Data(json.utf8))
    }

    private func disk(_ type: String, size: Int) -> String {
        """
        {"mediaType": "\(type)", "digest": "sha256:\(size)", "size": 10,
         "annotations": {"org.cirruslabs.tart.uncompressed-size": "\(size)",
                         "org.cirruslabs.tart.uncompressed-content-digest": "sha256:u\(size)"}}
        """
    }

    private let config = #"{"mediaType": "application/vnd.cirruslabs.tart.config.v1", "digest": "sha256:a", "size": 1}"#
    private let nvram = #"{"mediaType": "application/vnd.cirruslabs.tart.nvram.v1", "digest": "sha256:b", "size": 1}"#

    @Test func layersFollowEachOther() throws {
        let image = try TartImage(manifest: manifest([
            config,
            disk(TartImage.zstdDiskType, size: 512),
            disk(TartImage.lz4DiskType, size: 256),
            nvram,
        ].joined(separator: ",")))
        #expect(image.disk.map(\.offset) == [0, 512])
        #expect(image.disk.map(\.zstd) == [true, false])
        #expect(image.diskBytes == 768)
    }

    @Test func refusesWhatItCannotRead() throws {
        #expect(throws: ImageError.self) {
            try TartImage(manifest: manifest([config, disk("application/vnd.cirruslabs.tart.disk.v1", size: 1), nvram].joined(separator: ",")))
        }
        #expect(throws: ImageError.self) {
            try TartImage(manifest: manifest([config, disk(TartImage.zstdDiskType, size: 1)].joined(separator: ",")))
        }
        let unannotated = #"{"mediaType": "\#(TartImage.zstdDiskType)", "digest": "sha256:d", "size": 10}"#
        #expect(throws: ImageError.self) {
            try TartImage(manifest: manifest([config, unannotated, nvram].joined(separator: ",")))
        }
    }

    @Test func auxDropsTheHeader() throws {
        var nvram = Data(count: Int(VirtualMachine.auxBytes))
        nvram.replaceSubrange(0x4000..<0x4004, with: Data("HUFA".utf8))
        nvram[0x4000 + 100] = 0x5a
        let aux = try TartImage.aux(nvram: nvram)
        #expect(aux.count == nvram.count)
        #expect(aux.prefix(4) == Data("HUFA".utf8))
        #expect(aux[100] == 0x5a)
        #expect(throws: ImageError.self) { try TartImage.aux(nvram: Data(count: 1024)) }
    }

    /// Virtualization.framework stores the ECID as a 16 byte integer.
    @Test func ecidFromConfig() throws {
        let ecid: UInt64 = 0x8899_aabb_ccdd_eeff
        func bigEndian(_ value: UInt64) -> [UInt8] { withUnsafeBytes(of: value.bigEndian) { Array($0) } }
        let identifier = Array("bplist00".utf8) + [0xd1, 0x01, 0x02, 0x54] + Array("ECID".utf8) + [0x14] +
            bigEndian(0) + bigEndian(ecid) + [0x08, 0x0b, 0x10] + [UInt8](repeating: 0, count: 6) + [1, 1] +
            bigEndian(3) + bigEndian(0) + bigEndian(0x21)
        let model = try PropertyListSerialization.data(
            fromPropertyList: ["DataRepresentationVersion": 2, "PlatformVersion": 2, "MinimumSupportedOS": [13, 0, 0]],
            format: .binary,
            options: 0
        )
        let config: [String: Any] = [
            "version": 1, "os": "darwin", "arch": "arm64", "diskFormat": "raw",
            "ecid": Data(identifier).base64EncodedString(), "hardwareModel": model.base64EncodedString(),
        ]
        #expect(try TartImage.ecid(config: try JSONSerialization.data(withJSONObject: config)) == ecid)

        var asif = config
        asif["diskFormat"] = "asif"
        #expect(throws: ImageError.self) { try TartImage.ecid(config: try JSONSerialization.data(withJSONObject: asif)) }
    }
}

@Suite struct AppleLZ4Tests {
    @Test func overlappingMatch() throws {
        let block: [UInt8] = [0x35] + Array("abc".utf8) + [3, 0] + [0x10] + Array("X".utf8)
        #expect(try AppleLZ4.decodeBlock(block, size: 13, history: []) == Array("abcabcabcabcX".utf8))
    }

    @Test func streamReachesIntoTheLastBlock() throws {
        func le(_ value: Int) -> [UInt8] { withUnsafeBytes(of: UInt32(value).littleEndian) { Array($0) } }
        let payload: [UInt8] = [0x01, 5, 0, 0x10] + Array("!".utf8)
        let stream = Array("bv4-".utf8) + le(5) + Array("hello".utf8) +
            Array("bv41".utf8) + le(6) + le(payload.count) + payload + Array("bv4$".utf8)
        let file = FileManager.default.temporaryDirectory.appending(path: "lz4-\(UUID().uuidString)")
        try Data(stream).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var blocks: [String] = []
        try AppleLZ4.decode(try FileHandle(forReadingFrom: file)) { blocks.append(String(decoding: $0, as: UTF8.self)) }
        #expect(blocks == ["hello", "hello!"])
    }

    @Test func refusesAMatchBeforeTheStart() {
        #expect(throws: ImageError.self) { try AppleLZ4.decodeBlock([0x00, 9, 0, 0x10, 0x41], size: 5, history: []) }
    }

    /// Set VMAPPLE_TEST_LZ4 to `<layer file>=<its uncompressed digest>` to decode a real Tart layer.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VMAPPLE_TEST_LZ4"] != nil))
    func decodesARealLayer() throws {
        let setting = ProcessInfo.processInfo.environment["VMAPPLE_TEST_LZ4"]!.split(separator: "=").map(String.init)
        var decoded = Data()
        try AppleLZ4.decode(try FileHandle(forReadingFrom: URL(fileURLWithPath: setting[0]))) { decoded.append(contentsOf: $0) }
        #expect(Digest.sha256(decoded) == setting[1])
    }
}
