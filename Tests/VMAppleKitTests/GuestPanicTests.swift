import Testing
@testable import VMAppleKit

@Suite struct GuestPanicTests {
    let glued = """
    AppleKeyStore: operation failed
    AMFI: Denying core dump for pid 312 (launchd)panic(cpu 2 caller 0xfffffe0012345678): Kernel data abort.
    """

    @Test func findsAPanicAfterOtherOutputOnItsLine() {
        #expect(QEMUMachine.lastPanic(in: glued) != nil)
        #expect(QEMUMachine.restarted(log: glued))
    }

    @Test func ignoresOrdinaryMentionsOfPanic() {
        let log = "kern.panic(debug) set\nApplePSCI - system off\n"
        #expect(QEMUMachine.lastPanic(in: log) == nil)
        #expect(!QEMUMachine.restarted(log: log))
    }

    @Test func aPowerOffAfterThePanicIsNotARestart() {
        #expect(!QEMUMachine.restarted(log: glued + "\nApplePSCI - system off\n"))
    }

    @Test func aResetAfterAPowerOffIsARestart() {
        #expect(QEMUMachine.restarted(log: "ApplePSCI - system off\nApplePSCI - system reset\n"))
    }
}
