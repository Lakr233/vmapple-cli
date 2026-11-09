import Foundation
import Testing

@testable import VMAppleKit

@Suite struct APFSTests {
    @Test func fletcherChecksumVerifies() {
        var block = (0..<4096).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) }
        let sum = APFSContainer.checksum(block)
        withUnsafeBytes(of: sum.littleEndian) { block.replaceSubrange(0..<8, with: $0) }
        // Summing the body and then the stored checksum comes to zero.
        var low: UInt64 = 0
        var high: UInt64 = 0
        for offset in Array(stride(from: 8, to: block.count, by: 4)) + [0, 4] {
            low = (low + UInt64(block.le(offset, UInt32.self))) % 0xffff_ffff
            high = (high + low) % 0xffff_ffff
        }
        #expect(low == 0 && high == 0)
    }

    @Test func dataStreamSizeFromExtendedFields() {
        var inode = [UInt8](repeating: 0, count: 96)
        inode[92] = 2
        // A 16 byte name field, then the data stream.
        inode += [4, 0, 16, 0, 8, 0, 40, 0]
        inode += [UInt8](repeating: 0x41, count: 16)
        inode += [0x34, 0x12, 0, 0, 0, 0, 0, 0] + [UInt8](repeating: 0, count: 32)
        #expect(APFSVolume.dataStreamSize(inode) == 0x1234)
    }

    /// Set VMAPPLE_TEST_VM to a restored VM's directory to compare what its
    /// Preboot volume gives with what `restore` read from the IPSW.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VMAPPLE_TEST_VM"] != nil))
    func prebootMatchesTheRestore() throws {
        let machine = try VirtualMachine.open(
            at: URL(fileURLWithPath: ProcessInfo.processInfo.environment["VMAPPLE_TEST_VM"]!)
        )
        let systems = try PrebootSystem.read(disk: machine.disk)
        #expect(systems.count == 1)
        let system = try #require(systems.first)
        #expect("\(system.version ?? "?") (\(system.build ?? "?"))" == machine.configuration.installed)
        #expect(try system.handoffAddresses() == machine.configuration.handoffAddresses)
    }
}
