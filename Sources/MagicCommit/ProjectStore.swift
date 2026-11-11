import AppKit
import Foundation

struct Project: Identifiable, Codable, Hashable {
    var id = UUID()
    var path: String

    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var url: URL { URL(fileURLWithPath: path) }
}

enum Activity: Equatable {
    case committing, committingWIP, pushing
    case batch(current: Int, total: Int)

    var label: String {
        switch self {
        case .committing: return "Writing commit message…"
        case .committingWIP: return "Committing WIP…"
        case .pushing: return "Pushing…"
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

@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published private(set) var statuses: [UUID: GitStatus] = [:]
    @Published private(set) var activity: [UUID: Activity] = [:]
    @Published private(set) var logs: [UUID: ActionLog] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?

    private let defaultsKey = "projects"
    private var refreshLoop: Task<Void, Never>?

    var attentionCount: Int {
        projects.filter { statuses[$0.id]?.needsAttention == true }.count
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

    // MARK: Projects

    func promptAddProjects() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose one or more git repositories"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await addProjects(urls) }
    }

    func addProjects(_ urls: [URL]) async {
        var rejected: [String] = []
        for url in urls {
            guard let top = await Git.toplevel(of: url.path) else {
                rejected.append(url.lastPathComponent)
                continue
            }
            guard !projects.contains(where: { $0.path == top }) else { continue }
            let project = Project(path: top)
            projects.append(project)
            projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
        projects.removeAll { $0.id == project.id }
        statuses[project.id] = nil
        logs[project.id] = nil
        save()
    }

    // MARK: Status

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let current = projects
        let results = await withTaskGroup(of: (UUID, GitStatus).self) { group in
            for p in current {
                group.addTask { (p.id, await Git.status(at: p.path)) }
            }
            var out: [UUID: GitStatus] = [:]
            for await (id, status) in group { out[id] = status }
            return out
        }
        for (id, status) in results where activity[id] == nil {
            statuses[id] = status
        }
        lastRefresh = Date()
    }

    func refresh(_ project: Project) async {
        statuses[project.id] = await Git.status(at: project.path)
    }

    // MARK: Actions

    /// Runs `work`, showing `activity` meanwhile and a result banner afterwards.
    private func perform(
        _ project: Project,
        _ activity: Activity,
        failureTitle: String,
        work: @escaping () async -> ShellResult,
        successTitle: @escaping (ShellResult) async -> String
    ) {
        guard self.activity[project.id] == nil else { return }
        self.activity[project.id] = activity
        logs[project.id] = nil
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
            logs[project.id] = ActionLog(title: title, output: output, succeeded: result.succeeded)
            self.activity[project.id] = nil
            await refresh(project)
        }
    }

    func commit(_ project: Project) {
        perform(project, .committing, failureTitle: "Commit failed") {
            await Git.commit(at: project.path)
        } successTitle: { _ in
            await Git.lastCommitSubject(at: project.path).map { "Committed: \($0)" } ?? "Committed"
        }
    }

    func commitWIP(_ project: Project) {
        perform(project, .committingWIP, failureTitle: "WIP commit failed") {
            await Git.commitWIP(at: project.path)
        } successTitle: { _ in
            "Committed WIP"
        }
    }

    func batchOco(_ project: Project) {
        guard let status = statuses[project.id], let branch = status.branch else { return }
        let id = project.id
        perform(project, .batch(current: 0, total: status.wipCount), failureTitle: "Batch oco failed") {
            await Git.batchOco(at: project.path, branch: branch) { current, total in
                Task { @MainActor in
                    // Ignore late updates arriving after the batch finished.
                    guard case .batch = self.activity[id] else { return }
                    self.activity[id] = .batch(current: current, total: total)
                }
            }
        } successTitle: { result in
            let n = result.stdout.split(separator: "\n").filter { !$0.hasSuffix("(empty WIP)") }.count
            return "Renamed \(n) WIP commit\(n == 1 ? "" : "s")"
        }
    }

    func push(_ project: Project) {
        guard let status = statuses[project.id] else { return }
        if status.wipCount > 0 {
            let alert = NSAlert()
            alert.messageText = "Push \(status.wipCount) WIP commit\(status.wipCount == 1 ? "" : "s")?"
            alert.informativeText = "Use Batch oco first to give them real commit messages."
            alert.addButton(withTitle: "Batch oco")
            alert.addButton(withTitle: "Push Anyway")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            switch alert.runModal() {
            case .alertFirstButtonReturn: batchOco(project); return
            case .alertSecondButtonReturn: break
            default: return
            }
        }
        perform(project, .pushing, failureTitle: "Push failed") {
            await Git.push(at: project.path, status: status)
        } successTitle: { _ in
            "Pushed"
        }
    }

    func dismissLog(_ project: Project) {
        logs[project.id] = nil
    }
}
