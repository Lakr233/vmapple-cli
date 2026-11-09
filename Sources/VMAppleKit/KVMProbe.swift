import CKVMProbe
import Foundation

// MARK: - Cores

/// One kind of core on the host. KVM has to pass on every kind, because a vCPU
/// thread can move between them.
public struct CoreKind: Equatable, Sendable {
    public let part: String
    public let cpus: [Int]
}

public enum HostCores {
    public static func parse(cpuinfo: String) -> [CoreKind] {
        var partsByCPU: [(cpu: Int, part: String)] = []
        var current: Int?
        for line in cpuinfo.split(separator: "\n", omittingEmptySubsequences: false) {
            let fields = line.split(separator: ":", maxSplits: 1)
            guard fields.count == 2 else { continue }
            let key = fields[0].trimmingCharacters(in: .whitespaces)
            let value = fields[1].trimmingCharacters(in: .whitespaces)
            if key == "processor" {
                current = Int(value)
            } else if key == "CPU part", let cpu = current {
                partsByCPU.append((cpu, value))
            }
        }
        let parts = Dictionary(grouping: partsByCPU, by: \.part)
        return parts
            .map { CoreKind(part: $0.key, cpus: $0.value.map(\.cpu).sorted()) }
            .sorted { ($0.cpus.first ?? 0) < ($1.cpus.first ?? 0) }
    }

    public static func current() -> [CoreKind] {
        parse(cpuinfo: readCPUInfo())
    }

    /// procfs reports a size of zero, and `String(contentsOfFile:)` stops short.
    static func readCPUInfo() -> String {
        guard let handle = FileHandle(forReadingAtPath: "/proc/cpuinfo") else { return "" }
        defer { try? handle.close() }
        return String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
    }
}

// MARK: - Probe

public struct KVMProbeResult: Sendable {
    public let tgran16: UInt32
    public let paRange: UInt32
    public let ipaBits: Int32
    public let psci11: Bool
    public let mmu16K: Bool
    public let hypercallForwarded: Bool
    public let pointerAuthentication: Bool
    public let appleKeyRegisters: Bool
    public let counterFrequency: UInt64

    public var passed: Bool {
        psci11 && mmu16K && hypercallForwarded && pointerAuthentication
    }
}

public struct KVMProbeError: Error, CustomStringConvertible {
    public let description: String
}

public enum KVMProbe {
    /// Runs one throwaway guest pinned to `cpu`. Pins the calling thread.
    public static func run(cpu: Int) throws -> KVMProbeResult {
        var report = ckvm_report()
        guard ckvm_probe(Int32(cpu), &report) == 0 else {
            let message = withUnsafeBytes(of: &report.error) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            throw KVMProbeError(description: message)
        }
        return KVMProbeResult(
            tgran16: report.tgran16,
            paRange: report.pa_range,
            ipaBits: report.ipa_bits,
            psci11: report.psci_1_1 != 0,
            mmu16K: report.mmu_16k_ran != 0,
            hypercallForwarded: report.hvc_forwarded != 0,
            pointerAuthentication: report.pac_round_trip != 0,
            appleKeyRegisters: report.apple_key_registers != 0,
            counterFrequency: report.cntfrq
        )
    }
}
