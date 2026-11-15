import AppKit
import Foundation

struct Project: Identifiable, Codable, Hashable {
    var id = UUID()
    var path: String

    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var url: URL { URL(fileURLWithPath: path) }
}

enum Activity: Equatable {
    case committing, committingWIP, pushing, removing
    case batch(current: Int, total: Int)

    var label: String {
        switch self {
        case .committing: return "Writing commit message…"
        case .committingWIP: return "Committing WIP…"
        case .pushing: return "Pushing…"
        case .removing: return "Removing worktree…"
        case let .batch(current, total):
            return current == 0 ? "Preparing batch oco…" : "oco is renaming WIP \(current) of \(total)…"
        }
    }
}

struct ActionLog: Equatable {
    var title: String
    var output: String
    var succeeded: Bool
}

/// Whether two paths point at the same folder (git may spell them through symlinks, e.g. /private/var).
func samePath(_ a: String, _ b: String) -> Bool {
    a == b || URL(fileURLWithPath: a).resolvingSymlinksInPath().path == URL(fileURLWithPath: b).resolvingSymlinksInPath().path
}

/// A project's worktrees and their statuses, gathered off the main actor.
private struct Snapshot: Sendable {
    /// The repository's main worktree as git reports it (nil when it couldn't be listed).
    var mainPath: String?
    var worktrees: [Worktree]
    var statuses: [String: GitStatus]
}

/// A stored project is a repository (its main working tree, or a bare repository).
/// Its linked worktrees are discovered on every refresh and never stored, so they
/// appear and disappear on their own. Status, activity and logs are keyed by checkout path.
@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [Project] = []
    /// Every checkout of each project, the main one first.
    @Published private(set) var worktrees: [UUID: [Worktree]] = [:]
    @Published private(set) var statuses: [String: GitStatus] = [:]
    @Published private(set) var activity: [String: Activity] = [:]
    @Published private(set) var logs: [String: ActionLog] = [:]
    /// Projects whose clean worktrees are shown.
    @Published private(set) var expanded: Set<UUID> = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?

    private let defaultsKey = "projects"
    private var refreshLoop: Task<Void, Never>?

    /// Checkouts (main working trees and linked worktrees) with something to commit or push.
    var attentionCount: Int {
        projects.flatMap(checkouts).filter { statuses[$0.path]?.needsAttention == true }.count
    }

    init() {
        load()
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { await self?.refreshAll() }
        }
    }

    // MARK: Checkouts

    func checkouts(of project: Project) -> [Worktree] {
        worktrees[project.id] ?? [Worktree(path: project.path, isMain: true)]
    }

    func mainCheckout(of project: Project) -> Worktree {
        checkouts(of: project).first(where: \.isMain) ?? Worktree(path: project.path, isMain: true)
    }

    func linkedWorktrees(of project: Project) -> [Worktree] {
        checkouts(of: project).filter { !$0.isMain }
    }

    /// Worktrees shown even when the project is folded: anything to do, running or just done.
    func isProminent(_ worktree: Worktree) -> Bool {
        if activity[worktree.path] != nil || logs[worktree.path] != nil { return true }
        guard let status = statuses[worktree.path] else { return false }
        return status.needsAttention || status.wipCount > 0 || status.error != nil
    }

    /// Linked worktrees shown as rows: all when expanded, only prominent ones otherwise.
    func visibleWorktrees(of project: Project) -> [Worktree] {
        let linked = linkedWorktrees(of: project)
        return expanded.contains(project.id) ? linked : linked.filter(isProminent)
    }

    func toggleExpanded(_ project: Project) {
        if expanded.contains(project.id) { expanded.remove(project.id) } else { expanded.insert(project.id) }
    }

    // MARK: Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([Project].self, from: data) else { return }
        projects = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(projects) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private func sortProjects() {
        projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Projects

    func promptAddProjects() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose one or more git repositories or worktrees"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await addProjects(urls) }
    }

    /// Adds the repository of each folder. Picking a linked worktree adds its main
    /// repository instead (the worktree then shows under it).
    func addProjects(_ urls: [URL]) async {
        var rejected: [String] = []
        for url in urls {
            guard let main = await Git.mainWorktreePath(of: url.path) else {
                rejected.append(url.lastPathComponent)
                continue
            }
            let isWorktree = !samePath(main, url.path)
            if let existing = projects.first(where: { samePath($0.path, main) }) {
                if isWorktree { expanded.insert(existing.id) }
                await refresh(existing)
                continue
            }
            let project = Project(path: main)
            projects.append(project)
            if isWorktree { expanded.insert(project.id) }
            sortProjects()
            save()
            await refresh(project)
        }
        if !rejected.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Not a git repository"
            alert.informativeText = rejected.joined(separator: ", ")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    func remove(_ project: Project) {
        for checkout in checkouts(of: project) {
            statuses[checkout.path] = nil
            logs[checkout.path] = nil
        }
        projects.removeAll { $0.id == project.id }
        worktrees[project.id] = nil
        expanded.remove(project.id)
        save()
    }

    // MARK: Status

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let current = projects
        let results = await withTaskGroup(of: (Project, Snapshot).self) { group in
            for p in current {
                group.addTask { (p, await Self.snapshot(of: p)) }
            }
            var out: [(Project, Snapshot)] = []
            for await result in group { out.append(result) }
            return out
        }
        for (project, snapshot) in results { apply(snapshot, to: project) }
        dropStaleState()
        lastRefresh = Date()
    }

    /// Refreshes a project and all its worktrees.
    func refresh(_ project: Project) async {
        // The path may have changed (migration) since `project` was captured.
        let project = projects.first(where: { $0.id == project.id }) ?? project
        apply(await Self.snapshot(of: project), to: project)
        dropStaleState()
    }

    private nonisolated static func snapshot(of project: Project) async -> Snapshot {
        let mainOnly = [Worktree(path: project.path, isMain: true)]
        guard FileManager.default.fileExists(atPath: project.path) else {
            return Snapshot(mainPath: nil, worktrees: mainOnly, statuses: [project.path: GitStatus(error: "Folder not found")])
        }
        let listed = await Git.worktrees(at: project.path)
        var list = listed ?? mainOnly
        if listed != nil { await Git.removeStaleTempWorktrees(list, repo: project.path) }
        let mainPath = listed?.first?.path

        list.removeAll { w in
            !w.isMain && (Git.isTempWorktree(w) || w.isPrunable || !FileManager.default.fileExists(atPath: w.path))
        }
        // Keep the stored spelling of the main path so its state stays keyed the same.
        if let i = list.firstIndex(where: \.isMain), samePath(list[i].path, project.path) {
            list[i].path = project.path
        }
        let main = list.filter(\.isMain)
        let linked = list.filter { !$0.isMain }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        list = main + linked

        let checked = list.filter { !$0.isBare }
        let statuses = await withTaskGroup(of: (String, GitStatus).self) { group in
            for w in checked {
                group.addTask { (w.path, await Git.status(at: w.path)) }
            }
            var out: [String: GitStatus] = [:]
            for await (path, status) in group { out[path] = status }
            return out
        }
        return Snapshot(mainPath: mainPath, worktrees: list, statuses: statuses)
    }

    private func apply(_ snapshot: Snapshot, to project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }

        // A project saved as a linked worktree (or added before worktree support)
        // becomes its main repository.
        if let main = snapshot.mainPath, !samePath(main, projects[index].path) {
            if projects.contains(where: { $0.id != project.id && samePath($0.path, main) }) {
                remove(projects[index])
                return
            }
            projects[index].path = main
            expanded.insert(project.id)
            sortProjects()
            save()
        }

        worktrees[project.id] = snapshot.worktrees
        for (path, status) in snapshot.statuses where activity[path] == nil {
            statuses[path] = status
        }
    }

    /// Forgets statuses and logs of worktrees that no longer exist.
    private func dropStaleState() {
        let live = Set(projects.flatMap(checkouts).map(\.path))
        for path in statuses.keys where !live.contains(path) && activity[path] == nil {
            statuses[path] = nil
        }
        for path in logs.keys where !live.contains(path) && activity[path] == nil {
            logs[path] = nil
        }
    }

    // MARK: Actions

    /// Runs `work` on a checkout, showing `activity` meanwhile and a result banner afterwards.
    private func perform(
        _ checkout: Worktree,
        in project: Project,
        _ activity: Activity,
        failureTitle: String,
        work: @escaping () async -> ShellResult,
        successTitle: @escaping (ShellResult) async -> String
    ) {
        let key = checkout.path
        guard self.activity[key] == nil else { return }
        self.activity[key] = activity
        logs[key] = nil
        Task {
            let result = await work()
            var output = result.combinedOutput
            let title: String
            if result.succeeded {
                title = await successTitle(result)
            } else {
                title = failureTitle
                if output.isEmpty { output = "Exited with status \(result.status)" }
            }
            logs[key] = ActionLog(title: title, output: output, succeeded: result.succeeded)
            self.activity[key] = nil
            await refresh(project)
        }
    }

    func commit(_ checkout: Worktree, in project: Project) {
        perform(checkout, in: project, .committing, failureTitle: "Commit failed") {
            await Git.commit(at: checkout.path)
        } successTitle: { _ in
            await Git.lastCommitSubject(at: checkout.path).map { "Committed: \($0)" } ?? "Committed"
        }
    }

    func commitWIP(_ checkout: Worktree, in project: Project) {
        perform(checkout, in: project, .committingWIP, failureTitle: "WIP commit failed") {
            await Git.commitWIP(at: checkout.path)
        } successTitle: { _ in
            "Committed WIP"
        }
    }

    func batchOco(_ checkout: Worktree, in project: Project) {
        guard let status = statuses[checkout.path], let branch = status.branch else { return }
        let key = checkout.path
        perform(checkout, in: project, .batch(current: 0, total: status.wipCount), failureTitle: "Batch oco failed") {
            await Git.batchOco(at: checkout.path, branch: branch) { current, total in
                Task { @MainActor in
                    // Ignore late updates arriving after the batch finished.
                    guard case .batch = self.activity[key] else { return }
                    self.activity[key] = .batch(current: current, total: total)
                }
            }
        } successTitle: { result in
            let n = result.stdout.split(separator: "\n").filter { !$0.hasSuffix("(empty WIP)") }.count
            return "Renamed \(n) WIP commit\(n == 1 ? "" : "s")"
        }
    }

    func push(_ checkout: Worktree, in project: Project) {
        guard let status = statuses[checkout.path] else { return }
        if status.wipCount > 0 {
            let alert = NSAlert()
            alert.messageText = "Push \(status.wipCount) WIP commit\(status.wipCount == 1 ? "" : "s")?"
            alert.informativeText = "Use Batch oco first to give them real commit messages."
            alert.addButton(withTitle: "Batch oco")
            alert.addButton(withTitle: "Push Anyway")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            switch alert.runModal() {
            case .alertFirstButtonReturn: batchOco(checkout, in: project); return
            case .alertSecondButtonReturn: break
            default: return
            }
        }
        perform(checkout, in: project, .pushing, failureTitle: "Push failed") {
            await Git.push(at: checkout.path, status: status)
        } successTitle: { _ in
            "Pushed"
        }
    }

    /// Whether a linked worktree can be removed from the panel: clean and unlocked.
    func canRemove(_ checkout: Worktree) -> Bool {
        guard !checkout.isMain, !checkout.isLocked, activity[checkout.path] == nil,
              let status = statuses[checkout.path], status.error == nil else { return false }
        return !status.hasChanges
    }

    /// Deletes a clean linked worktree's folder after confirmation. Its branch is kept.
    func removeWorktree(_ checkout: Worktree, in project: Project) {
        guard canRemove(checkout) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove worktree \(checkout.name)?"
        alert.informativeText = "The folder \(checkout.path) is deleted. "
            + (checkout.branch.map { "The branch \($0) and its commits are kept." } ?? "Its commit stays reachable from the reflog.")
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let key = checkout.path
        activity[key] = .removing
        logs[key] = nil
        Task {
            let result = await Git.removeWorktree(checkout, repo: project.path)
            activity[key] = nil
            if result.succeeded {
                logs[mainCheckout(of: project).path] = ActionLog(title: "Removed worktree \(checkout.label)", output: "", succeeded: true)
            } else {
                logs[key] = ActionLog(title: "Couldn't remove worktree", output: result.combinedOutput, succeeded: false)
            }
            await refresh(project)
        }
    }

    func dismissLog(_ checkout: Worktree) {
        logs[checkout.path] = nil
    }
}
