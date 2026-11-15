import Foundation

/// Puts a fake `oco` (commits the staged changes with a fixed message) first on
/// the PATH of every command the tests run.
///
/// `Shell.environment` reads MAGIC_COMMIT_EXTRA_PATH only once, when the first
/// command runs, so every test class that runs commands calls `install()` in its
/// setUp: whichever runs first, the real `oco` is never reached.
enum FakeOco {
    static func install() { _ = bin }

    private static let bin: URL = {
        let bin = FileManager.default.temporaryDirectory
            .appendingPathComponent("magic-commit-tests-bin-\(getpid())")
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let oco = bin.appendingPathComponent("oco")
        try? """
        #!/bin/sh
        git commit -q -m "feat: generated message"
        """.write(to: oco, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: oco.path)
        setenv("MAGIC_COMMIT_EXTRA_PATH", bin.path, 1)
        precondition(FileManager.default.isExecutableFile(atPath: oco.path), "fake oco not installed")
        return bin
    }()
}
