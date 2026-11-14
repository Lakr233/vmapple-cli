import Foundation
import Testing
@testable import VMAppleKit

@Suite struct SharedCacheTests {
    @Test func machinesOfOneBuildShareADirectory() {
        let directory = QEMUMachine.sharedCacheDirectory(
            installed: "26.6.2 (25G83)", environment: ["XDG_CACHE_HOME": "/srv/cache"])
        #expect(directory?.path == "/srv/cache/vmapple-cli/reims/25G83")
    }

    @Test func homeCacheWhenXDGIsUnsetOrEmpty() {
        let home = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache/vmapple-cli/reims/26B123")
        #expect(QEMUMachine.sharedCacheDirectory(installed: "27.2 (26B123)", environment: [:])?.path == home.path)
        #expect(QEMUMachine.sharedCacheDirectory(installed: "27.2 (26B123)", environment: ["XDG_CACHE_HOME": ""])?.path == home.path)
    }

    @Test func unknownBuildsKeepTheMachineDirectory() {
        #expect(QEMUMachine.sharedCacheDirectory(installed: nil, environment: [:]) == nil)
        #expect(QEMUMachine.sharedCacheDirectory(installed: "27.2", environment: [:]) == nil)
        #expect(QEMUMachine.sharedCacheDirectory(installed: "27.2 (?)", environment: [:]) == nil)
        #expect(QEMUMachine.sharedCacheDirectory(installed: "27.2 (../x)", environment: [:]) == nil)
    }
}
