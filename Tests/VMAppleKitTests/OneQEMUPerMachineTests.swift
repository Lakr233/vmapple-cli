import Foundation
import Testing
@testable import VMAppleKit

@Suite struct OneQEMUPerMachineTests {
    @Test func aMachineWhoseMonitorAnswersIsNotStartedAgain() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "vm-\(UInt32.random(in: 0 ... .max))")
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try VirtualMachine.create(at: directory, diskGiB: 1)
        let running = try UnixSocket.listen(path: machine.qmpSocket.path)
        defer { running.close() }

        let options = QEMUOptions(executable: "/bin/false", rom: "", cpus: 1, memoryGiB: 1, bootArguments: "")
        #expect(throws: QEMUError.self) {
            try QEMUMachine(machine: machine, options: options).start()
        }
        #expect(FileManager.default.fileExists(atPath: machine.qmpSocket.path))
    }

    @Test func aProcessThatIgnoresSIGTERMIsKilledAfterTheDeadline() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; while :; do sleep 1; done"]
        try process.run()
        usleep(100_000)
        QEMUMachine.terminate(process, timeout: 0.2)
        #expect(!process.isRunning)
    }
}
