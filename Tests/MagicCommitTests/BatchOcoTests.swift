import XCTest
@testable import MagicCommit

/// End-to-end test of `Git.batchOco` against a throwaway repository,
/// with a fake `oco` that commits the staged changes with a fixed message.
final class BatchOcoTests: XCTestCase {
    private var root: URL!
    private var repo: String { root.appendingPathComponent("repo").path }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("magic-commit-tests-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)

        let fakeOco = bin.appendingPathComponent("oco")
        try """
        #!/bin/sh
        git commit -q -m "feat: generated message"
        """.write(to: fakeOco, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOco.path)

        // Read once by `Shell.environment`, so it must be set before the first command runs.
        setenv("MAGIC_COMMIT_EXTRA_PATH", bin.path, 1)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func git(_ args: String...) async throws -> String {
        let env = [
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
        ]
        let r = await Shell.run(["git"] + args, in: repo, extraEnvironment: env)
        guard r.succeeded else { throw NSError(domain: "git", code: Int(r.status), userInfo: [NSLocalizedDescriptionKey: r.combinedOutput]) }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func write(_ name: String, _ content: String) throws {
        try content.write(toFile: (repo as NSString).appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testRenamesWIPCommitsAndKeepsOthers() async throws {
        try await git("init", "-q", "-b", "main")
        try await git("config", "user.name", "Test")
        try await git("config", "user.email", "test@example.com")
        try write("a.txt", "a")
        try await git("add", "-A")
        try await git("commit", "-q", "-m", "Initial commit")

        try write("b.txt", "b")
        try await git("add", "-A")
        try await git("commit", "-q", "-m", "WIP")
        try write("c.txt", "c")
        try await git("add", "-A")
        try await git("commit", "-q", "-m", "Add c")
        try await git("commit", "-q", "--allow-empty", "-m", "WIP")

        let treeBefore = try await git("rev-parse", "HEAD^{tree}")
        let result = await Git.batchOco(at: repo, branch: "main") { _, _ in }
        XCTAssertTrue(result.succeeded, result.combinedOutput)

        let subjects = try await git("log", "--format=%s")
        XCTAssertEqual(subjects.split(separator: "\n"), ["Add c", "feat: generated message", "Initial commit"])
        let treeAfter = try await git("rev-parse", "HEAD^{tree}")
        XCTAssertEqual(treeBefore, treeAfter)
        let worktrees = try await git("worktree", "list")
        XCTAssertEqual(worktrees.split(separator: "\n").count, 1, "temporary worktree should be removed")
    }
}
