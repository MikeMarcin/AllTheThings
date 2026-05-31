@testable import AllTheThings
import Testing

@Suite("App runtime status formatter")
struct AppRuntimeStatusFormatterTests {
    @Test("window title prefers version without build suffix")
    func windowTitlePrefersVersionWithoutBuildSuffix() {
        #expect(AppRuntimeStatusFormatter.windowTitle(version: "0.6.1", build: "42") == "AllTheThings 0.6.1")
        #expect(AppRuntimeStatusFormatter.windowTitle(version: "0.6.1", build: nil) == "AllTheThings 0.6.1")
        #expect(AppRuntimeStatusFormatter.windowTitle(version: nil, build: "42") == "AllTheThings 42")
        #expect(AppRuntimeStatusFormatter.windowTitle(version: nil, build: nil) == "AllTheThings")
    }

    @Test("operation elapsed formats seconds minutes and hours")
    func operationElapsedFormatsDurations() {
        #expect(AppRuntimeStatusFormatter.operationElapsed(7.2) == "7s")
        #expect(AppRuntimeStatusFormatter.operationElapsed(65) == "1m 05s")
        #expect(AppRuntimeStatusFormatter.operationElapsed(3_720) == "1h 02m")
    }

    @Test("catch up status includes elapsed time")
    func catchUpStatusIncludesElapsedTime() {
        #expect(AppRuntimeStatusFormatter.catchUpStatus(elapsed: 12.4) == "Catching up changes • 12s")
    }
}
