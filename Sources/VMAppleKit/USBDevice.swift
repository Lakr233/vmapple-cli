import Foundation

public struct USBDeviceDescriptor: Sendable {
    public let vendor: UInt16
    public let product: UInt16
    public let serialIndex: UInt8
    public let configurations: UInt8

    init(_ bytes: [UInt8]) throws {
        guard bytes.count >= 18 else { throw USBError.malformed("short device descriptor") }
        vendor = UInt16(bytes[8]) | UInt16(bytes[9]) << 8
        product = UInt16(bytes[10]) | UInt16(bytes[11]) << 8
        serialIndex = bytes[16]
        configurations = bytes[17]
    }
}

/// The device a boot stage presents.
public struct USBDevice: Sendable {
    public let link: VUSBLink
    public let descriptor: USBDeviceDescriptor

    public func controlIn(type: UInt8, request: UInt8, value: UInt16, index: UInt16, length: UInt16) throws -> [UInt8] {
        try link.control(setup: setup(type, request, value, index, length))
    }

    public func controlOut(type: UInt8, request: UInt8, value: UInt16, index: UInt16, data: [UInt8] = []) throws {
        _ = try link.control(setup: setup(type, request, value, index, UInt16(data.count)), data: data, timeout: 10)
    }

    public func string(at index: UInt8) throws -> String {
        let bytes = try controlIn(type: 0x80, request: 6, value: 0x0300 | UInt16(index), index: 0x0409, length: 255)
        guard bytes.count > 2 else { return "" }
        let units = stride(from: 2, to: bytes.count - 1, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
        return String(decoding: units, as: UTF16.self)
    }

    public func setConfiguration(_ value: UInt8) throws {
        try controlOut(type: 0, request: 9, value: UInt16(value), index: 0)
    }

    public func setInterface(_ interface: UInt16, alternate: UInt16) throws {
        try controlOut(type: 1, request: 0x0b, value: alternate, index: interface)
    }

    private func setup(_ type: UInt8, _ request: UInt8, _ value: UInt16, _ index: UInt16, _ length: UInt16) -> [UInt8] {
        [
            type, request,
            UInt8(value & 0xff), UInt8(value >> 8),
            UInt8(index & 0xff), UInt8(index >> 8),
            UInt8(length & 0xff), UInt8(length >> 8),
        ]
    }
}

public enum USBProduct {
    public static let dfu: UInt16 = 0x1227
    public static let recovery: UInt16 = 0x1281
    public static let restore: UInt16 = 0x12ac
}

extension VUSBLink {
    /// Takes the guest to the next device in `products`. Stages come and go on
    /// their own, so a device that is not wanted is left alone until it leaves.
    public func waitForDevice(_ products: Set<UInt16>, timeout: TimeInterval) throws -> USBDevice {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw USBError.timeout("USB device \(products)") }
            let startingStage = currentStage
            do {
                try reset(timeout: remaining)
                let bytes = try control(setup: [0x80, 6, 0, 1, 0, 0, 18, 0])
                let descriptor = try USBDeviceDescriptor(bytes)
                if products.contains(descriptor.product) {
                    return USBDevice(link: self, descriptor: descriptor)
                }
                try waitForStageChange(after: startingStage, timeout: remaining)
            } catch USBError.unplugged {
                continue
            }
            usleep(200_000)
        }
    }
}
