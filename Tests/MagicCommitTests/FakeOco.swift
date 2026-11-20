import Foundation

/// Puts a fake `oco` (commits the staged changes with a fixed message), a fake
/// `claude` (prints a fenced message, saving its stdin) and a fake `opencode`
/// (prints JSON events, saving its stdin) first on the PATH of every command the tests run.
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
        let claude = bin.appendingPathComponent("claude")
        try? """
        #!/bin/sh
        cat > "$(git rev-parse --git-common-dir)/fake-claude-stdin"
        printf '```\\nfeat: claude message\\n\\nBody line.\\n```\\n'
        """.write(to: claude, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        let opencode = bin.appendingPathComponent("opencode")
        try? #"""
        #!/bin/sh
        cat > "$(git rev-parse --git-common-dir)/fake-opencode-stdin"
        echo '{"type":"step_start","part":{"messageID":"m1"}}'
        echo '{"type":"text","part":{"messageID":"m1","type":"text","text":"Let me look."}}'
        echo '{"type":"tool_use","part":{"messageID":"m1","tool":"read"}}'
        echo '{"type":"text","part":{"messageID":"m2","type":"text","text":"feat: opencode "}}'
        printf '%s\n' '{"type":"text","part":{"messageID":"m2","type":"text","text":"message\n\nBody line."}}'
        """#.write(to: opencode, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: opencode.path)
        setenv("MAGIC_COMMIT_EXTRA_PATH", bin.path, 1)
        precondition(FileManager.default.isExecutableFile(atPath: oco.path), "fake oco not installed")
        return bin
    }()
}
