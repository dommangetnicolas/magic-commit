import XCTest
@testable import MagicCommit

/// End-to-end test of `Git.batchOco` against a throwaway repository,
/// with a fake `oco` that commits the staged changes with a fixed message.
final class BatchOcoTests: XCTestCase {
    private var root: URL!
    private var repo: String { root.appendingPathComponent("repo").path }

    override func setUpWithError() throws {
        FakeOco.install()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("magic-commit-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
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
        let result = await Git.batchOco(at: repo, branch: "main", generator: .oco) { _, _ in }
        XCTAssertTrue(result.succeeded, result.combinedOutput)

        let subjects = try await git("log", "--format=%s")
        XCTAssertEqual(subjects.split(separator: "\n"), ["Add c", "feat: generated message", "Initial commit"])
        let treeAfter = try await git("rev-parse", "HEAD^{tree}")
        XCTAssertEqual(treeBefore, treeAfter)
        let worktrees = try await git("worktree", "list")
        XCTAssertEqual(worktrees.split(separator: "\n").count, 1, "temporary worktree should be removed")
    }

    func testRenamesWIPCommitsInLinkedWorktree() async throws {
        try await git("init", "-q", "-b", "main")
        try await git("config", "user.name", "Test")
        try await git("config", "user.email", "test@example.com")
        try write("a.txt", "a")
        try await git("add", "-A")
        try await git("commit", "-q", "-m", "Initial commit")

        let linked = root.appendingPathComponent("repo-feature").path
        try await git("worktree", "add", "-q", "-b", "feature", linked)
        try "b".write(toFile: (linked as NSString).appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let commitWIP = await Git.commitWIP(at: linked)
        XCTAssertTrue(commitWIP.succeeded, commitWIP.combinedOutput)
        let mainHead = try await git("rev-parse", "main")

        let result = await Git.batchOco(at: linked, branch: "feature", generator: .oco) { _, _ in }
        XCTAssertTrue(result.succeeded, result.combinedOutput)

        let subjects = try await git("log", "--format=%s", "feature")
        XCTAssertEqual(subjects.split(separator: "\n"), ["feat: generated message", "Initial commit"])
        let mainAfter = try await git("rev-parse", "main")
        XCTAssertEqual(mainHead, mainAfter, "main must be untouched")
        let status = await Git.status(at: linked)
        XCTAssertFalse(status.hasChanges, "linked worktree's files and index stay in sync")
        let worktrees = try await git("worktree", "list")
        XCTAssertEqual(worktrees.split(separator: "\n").count, 2, "temporary worktree should be removed")
    }

    func testClaudeGeneratorCommitsCleanedMessageAndKeepsAuthor() async throws {
        try await git("init", "-q", "-b", "main")
        try await git("config", "user.name", "Test")
        try await git("config", "user.email", "test@example.com")
        try write("a.txt", "a")
        try await git("add", "-A")
        try await git("commit", "-q", "-m", "Initial commit")

        try write("b.txt", "hello from b")
        try await git("add", "-A")
        try await git("commit", "-q", "-m", "WIP", "--author", "Someone Else <else@example.com>")

        let result = await Git.batchOco(at: repo, branch: "main", generator: .claude) { _, _ in }
        XCTAssertTrue(result.succeeded, result.combinedOutput)

        let message = try await git("log", "-1", "--format=%B")
        XCTAssertEqual(message, "feat: claude message\n\nBody line.")
        let author = try await git("log", "-1", "--format=%an <%ae>")
        XCTAssertEqual(author, "Someone Else <else@example.com>")
        let stdin = try String(contentsOfFile: "\(repo)/.git/fake-claude-stdin", encoding: .utf8)
        XCTAssertTrue(stdin.contains("+hello from b"), "claude should receive the WIP commit's diff")
        XCTAssertTrue(stdin.contains("- Initial commit"), "claude should see recent subjects")
    }

    func testClaudeGeneratorCommitsWorkingChanges() async throws {
        try await git("init", "-q", "-b", "main")
        try await git("config", "user.name", "Test")
        try await git("config", "user.email", "test@example.com")
        try write("a.txt", "a")
        let result = await Git.commit(at: repo, generator: .claude)
        XCTAssertTrue(result.succeeded, result.combinedOutput)
        let subject = try await git("log", "-1", "--format=%s")
        XCTAssertEqual(subject, "feat: claude message")
    }

    func testCleanMessage() {
        XCTAssertEqual(MessageGenerator.cleanMessage("```\nfix: x\n```"), "fix: x\n")
        XCTAssertEqual(MessageGenerator.cleanMessage("  \"fix: y\"  \n"), "fix: y\n")
        XCTAssertNil(MessageGenerator.cleanMessage("```\n```"))
    }
}
