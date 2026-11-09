import Foundation
import Testing

@testable import VMAppleKit

@Suite struct DERTests {
    @Test func shortAndLongLengths() {
        #expect(DER.length(0x7f) == [0x7f])
        #expect(DER.length(0x80) == [0x81, 0x80])
        #expect(DER.length(0x1234) == [0x82, 0x12, 0x34])
    }

    @Test func readsWhatItWrites() throws {
        let body = [UInt8](repeating: 7, count: 300)
        let element = DER.element(tag: 0x04, body)
        let read = try DER.read(element, at: 0)
        #expect(Array(element[read.body]) == body)
        #expect(read.next == element.count)
    }
}

@Suite struct IMG4Tests {
    private let im4p = DER.element(
        tag: 0x30,
        DER.element(tag: 0x16, Array("IM4P".utf8)) +
            DER.element(tag: 0x16, Array("krnl".utf8)) +
            DER.element(tag: 0x16, Array("1.0".utf8)) +
            DER.element(tag: 0x04, [1, 2, 3])
    )

    @Test func retagKeepsEverythingElse() throws {
        let retagged = try IMG4.retagged(im4p: im4p, tag: "rkrn")
        #expect(retagged.count == im4p.count)
        #expect(String(decoding: retagged[10..<14], as: UTF8.self) == "rkrn")
        #expect(try IMG4.payload(im4p: retagged) == [1, 2, 3])
    }

    @Test func emptyPolicyIsIdevicerestores() {
        #expect(IMG4.emptyLocalPolicy == [
            0x30, 0x14, 0x16, 0x04, 0x49, 0x4d, 0x34, 0x50, 0x16, 0x04, 0x6c,
            0x70, 0x6f, 0x6c, 0x16, 0x03, 0x31, 0x2e, 0x30, 0x04, 0x01, 0x00,
        ])
    }

    @Test func refusesOtherContainers() {
        #expect(throws: IMG4Error.self) {
            try IMG4.retagged(im4p: DER.element(tag: 0x30, DER.element(tag: 0x16, Array("IM4M".utf8))), tag: "rkrn")
        }
    }
}

@Suite struct DFUTests {
    @Test func suffixIsLibirecoverysForm() {
        let bytes = DFU.withSuffix(Array("123456789".utf8))
        #expect(bytes.count == 25)
        #expect(Array(bytes[9..<21]) == [0xff, 0xff, 0xff, 0xff, 0xac, 0x05, 0x00, 0x01, 0x55, 0x46, 0x44, 0x10])
        #expect(CRC32.checksum(Array("123456789".utf8)) == 0xcbf4_3926)
        #expect(bytes.littleEndianUInt32(at: 21) == ~CRC32.checksum(Array(bytes[..<21])))
    }

    @Test func descriptionLayout() {
        var raw = [UInt8](repeating: 0, count: 0x400)
        raw.replaceSubrange(0x200..<0x20f, with: Array("iBootStage1 for".utf8))
        raw[0x300] = 0x00
        raw[0x301] = 0xc0
        raw[0x302] = 0x06
        raw[0x303] = 0x70
        let bytes = DFU.ImageDescription(compressed: [1, 2], raw: raw).bytes
        #expect(bytes.count == 112)
        #expect(bytes.littleEndianUInt32(at: 0) == 0x4843_5450)
        #expect(bytes.littleEndianUInt32(at: 0x18) == 2)
        #expect(bytes.littleEndianUInt32(at: 0x1c) == 0x400)
        #expect(bytes.littleEndianUInt32(at: 0x20) == 0x7006_c000)
        #expect(bytes.littleEndianUInt32(at: 0x28) == 2)
    }

    @Test func bannerMovedInMacOS27() {
        var raw = [UInt8](repeating: 0, count: 0x400)
        raw.replaceSubrange(0x280..<0x28f, with: Array("iBootStage1 for".utf8))
        raw.replaceSubrange(0x380..<0x384, with: [0x00, 0xc0, 0x06, 0x70])
        #expect(DFU.ImageDescription(compressed: [], raw: raw).bytes.littleEndianUInt32(at: 0x20) == 0x7006_c000)
    }

    /// 27.2's iBEC returns its trampoline window as 0xe0a00000..0xe0a04000.
    @Test func trampolineWindowMovedInMacOS27() {
        let words: [UInt32] = [0xd503_201f, 0x52bc_1400, 0x52bc_1401, 0x5288_0002, 0x72bc_1402, 0xd65f_03c0]
        let raw = words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) } }
        #expect(IBootImage.trampolineWindow(raw: raw) == 0xe0a0_0000)
        #expect(IBootImage.handoffAddresses(raw: raw).first == 0xe0a0_0000)
        #expect(IBootImage.handoffAddresses(raw: [UInt8](repeating: 0, count: 64)).first == 0xaca0_0000)
    }
}

@Suite struct NonceTests {
    @Test func parsesIBootsProductString() {
        let ap = String(repeating: "AB", count: 32)
        let sep = String(repeating: "AA", count: 20)
        let nonces = DeviceNonces(productString: " NONC:\(ap) SNON:\(sep) CC:0:0")
        #expect(nonces?.ap == [UInt8](repeating: 0xab, count: 32))
        #expect(nonces?.sep == [UInt8](repeating: 0xaa, count: 20))
    }

    @Test func refusesAStringWithoutThem() {
        #expect(DeviceNonces(productString: "Apple Inc.") == nil)
    }
}

@Suite struct USBMuxTests {
    @Test func findsTheMuxInterface() {
        let descriptor: [UInt8] = [
            9, 2, 41, 0, 2, 4, 0, 0x80, 50,
            9, 4, 0, 0, 0, 0xff, 0xff, 0xff, 0,
            9, 4, 1, 0, 2, 0xff, 0xfe, 2, 0,
            7, 5, 0x01, 2, 0, 2, 0,
            7, 5, 0x81, 2, 0, 2, 0,
        ]
        let endpoints = USBMuxEndpoints.parse(configuration: descriptor)
        #expect(endpoints?.configuration == 4)
        #expect(endpoints?.input == 0x81)
        #expect(endpoints?.output == 0x01)
        #expect(endpoints?.maximumPacketSize == 512)
    }
}

@Suite struct FirmwareTests {
    @Test func picksTheEraseIdentity() {
        func identity(_ device: String, _ variant: String, _ behavior: String) -> [String: Any] {
            ["Info": ["DeviceClass": device, "Variant": variant, "RestoreBehavior": behavior]]
        }
        #expect(Firmware.isVirtualMacErase(identity("vma2macosap", "Customer Erase Install (IPSW)", "Erase")))
        #expect(!Firmware.isVirtualMacErase(identity("vma2macosap", "macOS Customer", "Erase")))
        #expect(!Firmware.isVirtualMacErase(identity("vma2macosap", "Customer Upgrade Install (IPSW)", "Update")))
        #expect(!Firmware.isVirtualMacErase(identity("j274ap", "Customer Erase Install (IPSW)", "Erase")))
    }
}

@Suite struct PNGTests {
    @Test func convertsAPixel() throws {
        let ppm = Array("P6\n1 1\n255\n".utf8) + [255, 0, 0]
        let png = try PNG.convert(ppm: ppm)
        #expect(Array(png[0..<8]) == [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        #expect(png.count == 8 + 25 + 12 + 2 + 5 + 4 + 4 + 12)
    }
}
