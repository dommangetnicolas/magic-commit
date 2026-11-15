import XCTest
@testable import MagicCommit

final class WorktreeParsingTests: XCTestCase {
    func testMainAndLinkedWorktrees() {
        let list = Git.parseWorktreeList("""
        worktree /code/app
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /code/app-feature
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/feature/login

        worktree /code/app-review
        HEAD 3333333333333333333333333333333333333333
        detached

        """)
        XCTAssertEqual(list.map(\.path), ["/code/app", "/code/app-feature", "/code/app-review"])
        XCTAssertEqual(list.map(\.isMain), [true, false, false])
        XCTAssertEqual(list[1].branch, "feature/login")
        XCTAssertEqual(list[1].label, "feature/login")
        XCTAssertNil(list[2].branch)
        XCTAssertTrue(list[2].isDetached)
        XCTAssertEqual(list[2].label, "detached @ 3333333")
    }

    func testBareLockedAndPrunable() {
        let list = Git.parseWorktreeList("""
        worktree /code/app.git
        bare

        worktree /Volumes/USB/app
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main
        locked on a removable drive

        worktree /code/gone
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/old
        locked
        prunable gitdir file points to non-existent location
        """)
        XCTAssertEqual(list.count, 3)
        XCTAssertTrue(list[0].isBare)
        XCTAssertTrue(list[0].isMain)
        XCTAssertNil(list[0].branch)
        XCTAssertEqual(list[1].lockReason, "on a removable drive")
        XCTAssertFalse(list[1].isPrunable)
        XCTAssertEqual(list[2].lockReason, "")
        XCTAssertTrue(list[2].isLocked)
        XCTAssertTrue(list[2].isPrunable)
    }

    func testTempWorktreeDetection() {
        let tmp = URL(fileURLWithPath: "/tmp/x")
        let temp = Worktree(path: "/tmp/x/magic-commit-ABC", isDetached: true, lockReason: "magic-commit pid 42")
        XCTAssertTrue(Git.isTempWorktree(temp, tempDirectory: tmp))
        XCTAssertEqual(Git.tempWorktreePID(temp), 42)
        XCTAssertFalse(Git.isTempWorktree(Worktree(path: "/code/magic-commit-site"), tempDirectory: tmp))
        XCTAssertFalse(Git.isTempWorktree(Worktree(path: "/tmp/x/magic-commit-ABC", isMain: true), tempDirectory: tmp))
        XCTAssertNil(Git.tempWorktreePID(Worktree(path: "/tmp/x/magic-commit-ABC", lockReason: "someone else")))
    }
}

/// Worktree discovery and actions against a throwaway repository.
final class WorktreeIntegrationTests: XCTestCase {
    private var root: URL!
    private var repo: String { root.appendingPathComponent("repo").path }
    private var linked: String { root.appendingPathComponent("repo-feature").path }

    override func setUp() async throws {
        FakeOco.install()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("magic-commit-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try await git(repo, "init", "-q", "-b", "main")
        try await git(repo, "config", "user.name", "Test")
        try await git(repo, "config", "user.email", "test@example.com")
        try await git(repo, "config", "commit.gpgsign", "false")
        try await git(repo, "commit", "-q", "--allow-empty", "-m", "Initial commit")
        try await git(repo, "worktree", "add", "-q", "-b", "feature", linked)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func git(_ dir: String, _ args: String...) async throws -> String {
        let env = [
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
        ]
        let r = await Shell.run(["git"] + args, in: dir, extraEnvironment: env)
        guard r.succeeded else { throw NSError(domain: "git", code: Int(r.status), userInfo: [NSLocalizedDescriptionKey: r.combinedOutput]) }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testMainWorktreeResolvesFromLinkedWorktreeAndSubfolder() async throws {
        let sub = (linked as NSString).appendingPathComponent("src")
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        for path in [repo, linked, sub] {
            let main = await Git.mainWorktreePath(of: path)
            XCTAssertTrue(main.map { samePath($0, repo) } ?? false, "\(path) → \(main ?? "nil")")
        }
        let notRepo = await Git.mainWorktreePath(of: root.path)
        XCTAssertNil(notRepo)
    }

    func testListsWorktreesAndStatusPerCheckout() async throws {
        let listed = await Git.worktrees(at: repo)
        let list = try XCTUnwrap(listed)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[1].branch, "feature")

        try "x".write(toFile: (linked as NSString).appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        let mainStatus = await Git.status(at: repo)
        let linkedStatus = await Git.status(at: linked)
        XCTAssertEqual(mainStatus.branch, "main")
        XCTAssertFalse(mainStatus.hasChanges)
        XCTAssertEqual(linkedStatus.branch, "feature")
        XCTAssertEqual(linkedStatus.changes, 1)
    }

    func testStaleTempWorktreeIsRemovedButLiveOneKept() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let stale = tmp.appendingPathComponent("magic-commit-\(UUID().uuidString)").path
        let live = tmp.appendingPathComponent("magic-commit-\(UUID().uuidString)").path
        defer {
            try? FileManager.default.removeItem(atPath: stale)
            try? FileManager.default.removeItem(atPath: live)
        }
        // PID 99999999 can't exist; our own PID is alive.
        try await git(repo, "worktree", "add", "-q", "--detach", "--lock", "--reason", "magic-commit pid 99999999", stale, "HEAD")
        try await git(repo, "worktree", "add", "-q", "--detach", "--lock", "--reason", Git.tempWorktreeLockReason, live, "HEAD")

        let listedBefore = await Git.worktrees(at: repo)
        let before = try XCTUnwrap(listedBefore)
        XCTAssertEqual(before.filter { Git.isTempWorktree($0) }.count, 2)
        await Git.removeStaleTempWorktrees(before, repo: repo)

        let listedAfter = await Git.worktrees(at: repo)
        let after = try XCTUnwrap(listedAfter)
        let temps = after.filter { Git.isTempWorktree($0) }
        XCTAssertEqual(temps.count, 1)
        XCTAssertTrue(samePath(temps[0].path, live))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale))
        try await git(repo, "worktree", "remove", "--force", "--force", live)
    }

    func testRemoveWorktreeKeepsBranchAndRefusesDirty() async throws {
        let listed = await Git.worktrees(at: repo)
        let worktree = try XCTUnwrap(listed?.last)
        try "x".write(toFile: (linked as NSString).appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        let refused = await Git.removeWorktree(worktree, repo: repo)
        XCTAssertFalse(refused.succeeded)

        try FileManager.default.removeItem(atPath: (linked as NSString).appendingPathComponent("x.txt"))
        let removed = await Git.removeWorktree(worktree, repo: repo)
        XCTAssertTrue(removed.succeeded, removed.combinedOutput)
        XCTAssertFalse(FileManager.default.fileExists(atPath: linked))
        let branch = try await git(repo, "branch", "--list", "feature")
        XCTAssertFalse(branch.isEmpty)
    }
}
