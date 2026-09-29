@testable import CameraToolkitCore
import Darwin
import Foundation
import XCTest

/// The sidecar's stderr handler must come off when the sidecar exits: a
/// `readabilityHandler` left on a pipe at end of file is called again at
/// once with empty data, forever (each finished face scan left a core
/// spinning in the running app).
final class FaceSidecarPipeTests: XCTestCase {
    private func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    func testAnExitedSidecarLeavesNoHandlerSpinning() throws {
        guard FaceSidecarInstallation.scriptURL != nil else { throw XCTSkip("no bundled sidecar script in this build") }
        try withTemporaryDirectory { root in
            // A stand-in "python": ready line on stdout, a line on stderr,
            // then exit, closing both pipes.
            let python = root.appendingPathComponent("venv/bin/python")
            _ = try writeFile(python, """
            #!/bin/sh
            echo '{"event":"ready","pack":"test","insightface":"0","onnxruntime":"0","providers":[]}'
            echo 'warming up' >&2
            exit 0
            """)
            chmod(python.path, 0o755)
            _ = try writeFile(root.appendingPathComponent("models/buffalo_l/w600k_r50.onnx"), Data())
            let sidecar = try FaceSidecarProcess(installation: FaceSidecarInstallation(root: root), startupTimeout: 10)
            let deadline = Date().addingTimeInterval(5)
            while sidecar.isRunning, Date() < deadline { usleep(20_000) }
            XCTAssertFalse(sidecar.isRunning)
            usleep(200_000)  // Let the stderr EOF arrive.

            let before = processCPUSeconds()
            usleep(1_000_000)
            let spent = processCPUSeconds() - before
            XCTAssertLessThan(spent, 0.3, "about \(spent) s of CPU in 1 s after the sidecar exited: a pipe handler is spinning")
            withExtendedLifetime(sidecar) {}
        }
    }
}
