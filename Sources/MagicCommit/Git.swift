import Foundation

/// One checkout of a repository: the main working tree or a linked worktree.
struct Worktree: Identifiable, Hashable {
    var path: String
    /// Short branch name; nil when detached (or bare).
    var branch: String?
    var head: String?
    var isMain = false
    var isBare = false
    var isDetached = false
    /// Lock reason (possibly empty) when locked.
    var lockReason: String?
    var isPrunable = false

    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var url: URL { URL(fileURLWithPath: path) }
    var isLocked: Bool { lockReason != nil }
    /// Branch name, or the short commit for a detached worktree.
    var label: String { branch ?? head.map { "detached @ \($0.prefix(7))" } ?? "detached" }
}

struct GitStatus: Equatable {
    var branch: String?
    var upstream: String?
    /// Remote to push to when the branch has no upstream yet.
    var pushRemote: String?
    var changes = 0
    var ahead = 0
    var behind = 0
    /// Unpushed commits whose subject starts with "WIP".
    var wipCount = 0
    var error: String?

    var hasChanges: Bool { changes > 0 }
    var canPush: Bool { ahead > 0 && branch != nil && (upstream != nil || pushRemote != nil) }
    var needsAttention: Bool { hasChanges || canPush }
}

enum Git {
    static func toplevel(of path: String) async -> String? {
        let r = await Shell.run(["git", "rev-parse", "--show-toplevel"], in: path)
        guard r.succeeded else { return nil }
        let top = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return top.isEmpty ? nil : top
    }

    // MARK: Worktrees

    /// Path of the repository's main working tree (or of the bare repository),
    /// from any of its worktrees or subfolders. Nil when `path` isn't in a git repository.
    static func mainWorktreePath(of path: String) async -> String? {
        if let main = await worktrees(at: path)?.first { return main.path }
        return await toplevel(of: path)
    }

    /// All worktrees of the repository containing `path`, the main one first.
    static func worktrees(at path: String) async -> [Worktree]? {
        let r = await Shell.run(["git", "worktree", "list", "--porcelain"], in: path)
        guard r.succeeded else { return nil }
        let list = parseWorktreeList(r.stdout)
        return list.isEmpty ? nil : list
    }

    /// Parses `git worktree list --porcelain`: blocks of `worktree <path>`, `HEAD <sha>`,
    /// `branch refs/heads/<name>`, `detached`, `bare`, `locked [reason]`, `prunable [reason]`.
    static func parseWorktreeList(_ output: String) -> [Worktree] {
        var result: [Worktree] = []
        var current: Worktree?
        func flush() {
            if let w = current { result.append(w) }
            current = nil
        }
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.isEmpty { flush(); continue }
            let (key, value): (String, String) = {
                guard let space = line.firstIndex(of: " ") else { return (line, "") }
                return (String(line[..<space]), String(line[line.index(after: space)...]))
            }()
            if key == "worktree" {
                flush()
                current = Worktree(path: value, isMain: result.isEmpty)
                continue
            }
            guard current != nil else { continue }
            switch key {
            case "HEAD": current?.head = value
            case "branch":
                current?.branch = value.hasPrefix("refs/heads/") ? String(value.dropFirst("refs/heads/".count)) : value
            case "detached": current?.isDetached = true
            case "bare": current?.isBare = true
            case "locked": current?.lockReason = value
            case "prunable": current?.isPrunable = true
            default: break
            }
        }
        flush()
        return result
    }

    static var tempWorktreeLockReason: String { "magic-commit pid \(getpid())" }

    /// Whether `worktree` is one of the temporary worktrees Batch oco creates.
    static func isTempWorktree(_ worktree: Worktree, tempDirectory: URL = FileManager.default.temporaryDirectory) -> Bool {
        let url = worktree.url
        return !worktree.isMain && url.lastPathComponent.hasPrefix("magic-commit-")
            && url.deletingLastPathComponent().resolvingSymlinksInPath().path
            == tempDirectory.resolvingSymlinksInPath().path
    }

    /// PID recorded in a temporary worktree's lock reason.
    static func tempWorktreePID(_ worktree: Worktree) -> pid_t? {
        guard let reason = worktree.lockReason, reason.hasPrefix("magic-commit pid ") else { return nil }
        return pid_t(reason.dropFirst("magic-commit pid ".count))
    }

    /// Removes temporary worktrees left behind by a Batch oco that never finished
    /// (app crashed or was killed). Those whose process is still alive are kept.
    static func removeStaleTempWorktrees(_ worktrees: [Worktree], repo: String) async {
        for w in worktrees where isTempWorktree(w) {
            if let pid = tempWorktreePID(w), kill(pid, 0) == 0 || errno == EPERM { continue }
            let removed = await Shell.run(["git", "worktree", "remove", "--force", "--force", w.path], in: repo)
            if !removed.succeeded {
                // Folder already gone: drop the registration.
                _ = await Shell.run(["git", "worktree", "unlock", w.path], in: repo)
                _ = await Shell.run(["git", "worktree", "prune"], in: repo)
            }
        }
    }

    /// Deletes a linked worktree's folder. Git refuses if it has uncommitted changes.
    /// Its branch and commits are kept.
    static func removeWorktree(_ worktree: Worktree, repo: String) async -> ShellResult {
        await Shell.run(["git", "worktree", "remove", worktree.path], in: repo)
    }

    // MARK: Status

    static func status(at path: String) async -> GitStatus {
        guard FileManager.default.fileExists(atPath: path) else {
            return GitStatus(error: "Folder not found")
        }
        let r = await Shell.run(["git", "status", "--porcelain=v1", "--branch"], in: path)
        guard r.succeeded else {
            let msg = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return GitStatus(error: msg.isEmpty ? "Not a git repository" : msg)
        }

        var s = GitStatus()
        var lines = r.stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if let head = lines.first, head.hasPrefix("## ") {
            parseBranchLine(String(head.dropFirst(3)), into: &s)
            lines.removeFirst()
        }
        s.changes = lines.count

        // No upstream: count commits that exist on no remote at all.
        if s.upstream == nil, s.branch != nil {
            let remotes = await Shell.run(["git", "remote"], in: path).stdout
                .split(separator: "\n").map(String.init)
            if !remotes.isEmpty {
                s.pushRemote = remotes.contains("origin") ? "origin" : remotes[0]
                let c = await Shell.run(["git", "rev-list", "--count", "HEAD", "--not", "--remotes"], in: path)
                s.ahead = c.succeeded ? Int(c.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 : 0
            }
        }

        if s.branch != nil {
            let subjects = await Shell.run(unpushedLogArgs(format: "%s"), in: path)
            if subjects.succeeded {
                s.wipCount = subjects.stdout.split(separator: "\n").filter { isWIP(String($0)) }.count
            }
        }
        return s
    }

    static let wipMessage = "WIP"
    private static let maxRewrite = 100

    static func isWIP(_ subject: String) -> Bool {
        subject.range(of: #"^\s*wip\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Commits on HEAD not on any remote (all of history when there's no remote), newest first.
    private static func unpushedLogArgs(format: String, reverse: Bool = false) -> [String] {
        ["git", "log"] + (reverse ? ["--reverse"] : []) +
            ["-n", "\(maxRewrite)", "--format=\(format)", "HEAD", "--not", "--remotes"]
    }

    /// Parses the `## …` header of `git status --branch`, e.g.
    /// `main...origin/main [ahead 2, behind 1]`, `main`, `No commits yet on main`, `HEAD (no branch)`.
    static func parseBranchLine(_ line: String, into s: inout GitStatus) {
        var main = line
        var tracking = ""
        if let r = line.range(of: " [") {
            main = String(line[..<r.lowerBound])
            tracking = String(line[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "]"))
        }

        for prefix in ["No commits yet on ", "Initial commit on "] where main.hasPrefix(prefix) {
            s.branch = String(main.dropFirst(prefix.count))
            return
        }
        if main.hasPrefix("HEAD (no branch)") { return }

        if let r = main.range(of: "...") {
            s.branch = String(main[..<r.lowerBound])
            s.upstream = String(main[r.upperBound...])
        } else {
            s.branch = main
        }

        if tracking == "gone" {
            s.upstream = nil
            return
        }
        for part in tracking.split(separator: ",") {
            let words = part.trimmingCharacters(in: .whitespaces).split(separator: " ")
            guard words.count == 2, let n = Int(words[1]) else { continue }
            if words[0] == "ahead" { s.ahead = n }
            if words[0] == "behind" { s.behind = n }
        }
    }

    /// Stages everything when nothing is staged yet (keeps a manual partial staging otherwise).
    private static func stageAllIfNothingStaged(at path: String) async -> ShellResult? {
        let staged = await Shell.run(["git", "diff", "--cached", "--quiet"], in: path)
        guard staged.status == 0 else { return nil }
        let add = await Shell.run(["git", "add", "-A"], in: path)
        return add.succeeded ? nil : add
    }

    /// Quick commit with a "WIP" message, to be renamed later by `batchOco`.
    static func commitWIP(at path: String) async -> ShellResult {
        if let failure = await stageAllIfNothingStaged(at: path) { return failure }
        return await Shell.run(["git", "commit", "-m", wipMessage], in: path, timeout: 300)
    }

    /// Stages everything if nothing is staged, then lets `generator` write and create the commit.
    static func commit(at path: String, generator: MessageGenerator = .current) async -> ShellResult {
        if let failure = await stageAllIfNothingStaged(at: path) { return failure }
        return await generator.commit(at: path)
    }

    static func push(at path: String, status: GitStatus) async -> ShellResult {
        if status.upstream == nil, let remote = status.pushRemote, let branch = status.branch {
            return await Shell.run(["git", "push", "-u", remote, branch], in: path, timeout: 300)
        }
        return await Shell.run(["git", "push"], in: path, timeout: 300)
    }

    // MARK: Batch oco

    private struct LogEntry {
        let hash: String
        let parents: [String]
        let subject: String
    }

    /// Gives every unpushed WIP commit a real message generated by `generator` (oco, claude or opencode).
    ///
    /// The commits from the oldest WIP one up to HEAD are replayed in a temporary
    /// detached worktree: each WIP commit is re-committed through the generator (which sees
    /// exactly that commit's diff staged), others are re-committed unchanged. The
    /// branch ref is then swapped atomically, only if HEAD hasn't moved meanwhile.
    /// The final tree is identical, so the user's working tree and index are untouched.
    static func batchOco(
        at path: String,
        branch: String,
        generator: MessageGenerator = .current,
        progress: @escaping @Sendable (_ current: Int, _ total: Int) -> Void
    ) async -> ShellResult {
        func fail(_ message: String, _ result: ShellResult? = nil) -> ShellResult {
            let detail = result?.combinedOutput ?? ""
            return ShellResult(status: 1, stdout: "", stderr: detail.isEmpty ? message : "\(message)\n\n\(detail)")
        }

        let log = await Shell.run(unpushedLogArgs(format: "%H%x09%P%x09%s", reverse: true), in: path)
        guard log.succeeded else { return fail("Couldn't list commits.", log) }
        let entries: [LogEntry] = log.stdout.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { return nil }
            return LogEntry(hash: parts[0], parents: parts[1].split(separator: " ").map(String.init), subject: parts[2])
        }
        guard let firstWIP = entries.firstIndex(where: { isWIP($0.subject) }) else {
            return fail("No unpushed WIP commits.")
        }
        let chain = Array(entries[firstWIP...])
        for (i, entry) in chain.enumerated() {
            guard entry.parents.count == 1 else {
                return fail("Can't rewrite: \(entry.parents.isEmpty ? "the root commit" : "a merge commit") is in the range (\(entry.hash.prefix(7))).")
            }
            if i > 0, entry.parents[0] != chain[i - 1].hash {
                return fail("Can't rewrite: history isn't linear.")
            }
        }

        let headResult = await Shell.run(["git", "rev-parse", "HEAD"], in: path)
        let oldHead = headResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard headResult.succeeded, oldHead == chain.last?.hash else { return fail("HEAD moved, try again.") }

        let worktree = FileManager.default.temporaryDirectory
            .appendingPathComponent("magic-commit-\(UUID().uuidString)").path
        // Locked with our PID so a later run can tell a leftover (app crashed) from a batch in progress.
        let add = await Shell.run(
            ["git", "worktree", "add", "--detach", "--lock", "--reason", tempWorktreeLockReason, worktree, chain[0].parents[0]],
            in: path
        )
        guard add.succeeded else { return fail("Couldn't create a temporary worktree.", add) }

        let result = await replay(chain, in: worktree, generator: generator, progress: progress, fail: fail)
        var outcome = result.result
        if let newHead = result.newHead {
            let trees = await Shell.run(["git", "rev-parse", "\(oldHead)^{tree}", "\(newHead)^{tree}"], in: path)
            let lines = trees.stdout.split(separator: "\n")
            if !trees.succeeded || lines.count != 2 || lines[0] != lines[1] {
                outcome = fail("Rewritten history doesn't match the original content; nothing was changed.")
            } else {
                let update = await Shell.run(
                    ["git", "update-ref", "-m", "magic-commit: batch oco", "refs/heads/\(branch)", newHead, oldHead],
                    in: path
                )
                if !update.succeeded { outcome = fail("The branch changed while rewriting; nothing was changed.", update) }
            }
        }
        // Twice --force: the worktree is locked.
        _ = await Shell.run(["git", "worktree", "remove", "--force", "--force", worktree], in: path)
        return outcome
    }

    private static func replay(
        _ chain: [LogEntry],
        in worktree: String,
        generator: MessageGenerator,
        progress: @Sendable (Int, Int) -> Void,
        fail: (String, ShellResult?) -> ShellResult
    ) async -> (result: ShellResult, newHead: String?) {
        // Empty WIP commits carry nothing to describe: they're dropped.
        var emptyWIP = Set<String>()
        for entry in chain where isWIP(entry.subject) {
            let diff = await Shell.run(["git", "diff", "--quiet", entry.parents[0], entry.hash], in: worktree)
            if diff.status == 0 { emptyWIP.insert(entry.hash) }
        }
        let total = chain.filter { isWIP($0.subject) && !emptyWIP.contains($0.hash) }.count
        var current = 0
        var summary: [String] = []

        for entry in chain {
            let short = String(entry.hash.prefix(7))
            if emptyWIP.contains(entry.hash) {
                summary.append("\(short) → dropped (empty WIP)")
                continue
            }
            let pick = await Shell.run(["git", "cherry-pick", "--no-commit", entry.hash], in: worktree)
            guard pick.succeeded else { return (fail("Couldn't replay \(short).", pick), nil) }

            if isWIP(entry.subject) {
                current += 1
                progress(current, total)
                let before = await Shell.run(["git", "rev-parse", "HEAD"], in: worktree).stdout
                let author = await Shell.run(["git", "show", "-s", "--format=%an%x00%ae%x00%aI", entry.hash], in: worktree)
                let fields = author.stdout.trimmingCharacters(in: .newlines).components(separatedBy: "\0")
                var env: [String: String] = [:]
                if fields.count == 3 {
                    env["GIT_AUTHOR_NAME"] = fields[0]
                    env["GIT_AUTHOR_EMAIL"] = fields[1]
                    env["GIT_AUTHOR_DATE"] = fields[2]
                }
                let generated = await generator.commit(at: worktree, extraEnvironment: env)
                let after = await Shell.run(["git", "rev-parse", "HEAD"], in: worktree).stdout
                guard generated.succeeded, after != before else {
                    return (fail("\(generator.shortName) failed on \(short) (\(current)/\(total)); nothing was changed.", generated), nil)
                }
                let subject = await Shell.run(["git", "log", "-1", "--format=%s"], in: worktree).stdout
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                summary.append("\(short) → \(subject)")
            } else {
                // Non-WIP commit: keep message, author and date.
                let commit = await Shell.run(["git", "commit", "--allow-empty", "--no-verify", "-C", entry.hash], in: worktree)
                guard commit.succeeded else { return (fail("Couldn't replay \(short).", commit), nil) }
            }
        }

        let head = await Shell.run(["git", "rev-parse", "HEAD"], in: worktree)
        guard head.succeeded else { return (fail("Couldn't read the rewritten HEAD.", head), nil) }
        return (
            ShellResult(status: 0, stdout: summary.joined(separator: "\n"), stderr: ""),
            head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func lastCommitSubject(at path: String) async -> String? {
        let r = await Shell.run(["git", "log", "-1", "--pretty=%s"], in: path)
        let s = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.succeeded && !s.isEmpty ? s : nil
    }
}
