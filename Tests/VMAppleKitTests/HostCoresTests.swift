import Testing
@testable import VMAppleKit

@Suite struct HostCoresTests {
    @Test func groupsBigAndLittleCores() {
        let cpuinfo = """
        processor\t: 0
        BogoMIPS\t: 2000.00
        CPU part\t: 0xd87

        processor\t: 1
        CPU part\t: 0xd87

        processor\t: 5
        CPU part\t: 0xd85
        """
        #expect(HostCores.parse(cpuinfo: cpuinfo) == [
            CoreKind(part: "0xd87", cpus: [0, 1]),
            CoreKind(part: "0xd85", cpus: [5]),
        ])
    }

    @Test func emptyInputHasNoCores() {
        #expect(HostCores.parse(cpuinfo: "").isEmpty)
    }
}
