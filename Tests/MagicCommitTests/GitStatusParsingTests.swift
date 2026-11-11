import XCTest
@testable import MagicCommit

final class GitStatusParsingTests: XCTestCase {
    private func parse(_ line: String) -> GitStatus {
        var s = GitStatus()
        Git.parseBranchLine(line, into: &s)
        return s
    }

    func testTrackingBranchAheadAndBehind() {
        let s = parse("main...origin/main [ahead 2, behind 1]")
        XCTAssertEqual(s.branch, "main")
        XCTAssertEqual(s.upstream, "origin/main")
        XCTAssertEqual(s.ahead, 2)
        XCTAssertEqual(s.behind, 1)
    }

    func testBranchWithoutUpstream() {
        let s = parse("feature/login")
        XCTAssertEqual(s.branch, "feature/login")
        XCTAssertNil(s.upstream)
        XCTAssertEqual(s.ahead, 0)
    }

    func testUpstreamGone() {
        let s = parse("main...origin/main [gone]")
        XCTAssertEqual(s.branch, "main")
        XCTAssertNil(s.upstream)
    }

    func testNoCommitsYet() {
        XCTAssertEqual(parse("No commits yet on main").branch, "main")
    }

    func testDetachedHead() {
        let s = parse("HEAD (no branch)")
        XCTAssertNil(s.branch)
        XCTAssertFalse(s.canPush)
    }

    func testIsWIP() {
        XCTAssertTrue(Git.isWIP("WIP"))
        XCTAssertTrue(Git.isWIP("wip: half done"))
        XCTAssertTrue(Git.isWIP("  WIP login form"))
        XCTAssertFalse(Git.isWIP("Wipe cache on logout"))
        XCTAssertFalse(Git.isWIP("Fix WIP handling"))
    }
}
