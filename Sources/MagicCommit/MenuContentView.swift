import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Theme

enum Theme {
    static let magic = LinearGradient(
        colors: [Color(red: 0.55, green: 0.36, blue: 0.96), Color(red: 0.93, green: 0.35, blue: 0.62)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let batch = LinearGradient(
        colors: [Color(red: 1.0, green: 0.58, blue: 0.20), Color(red: 0.93, green: 0.35, blue: 0.52)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let push = LinearGradient(
        colors: [Color(red: 0.20, green: 0.55, blue: 1.0), Color(red: 0.25, green: 0.40, blue: 0.95)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

struct PillButtonStyle<S: ShapeStyle>: ButtonStyle {
    var fill: S
    var foreground: Color = .white
    var shadow = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(fill))
            .shadow(color: .black.opacity(shadow ? 0.15 : 0), radius: 2, y: 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct IconButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.08 : 0))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

// MARK: - Panel

struct MenuContentView: View {
    @EnvironmentObject private var store: ProjectStore
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            content
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        .background(PanelHeightSync(height: contentHeight))
        // The MenuBarExtra window is reused, so onAppear only fires once.
        // Refresh every time the panel becomes key (i.e. is opened).
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await store.refreshAll() }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Theme.magic)
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text("Magic Commit").font(.system(size: 13, weight: .semibold))
                Text(headerSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            Spacer()

            Button {
                Task { await store.refreshAll() }
            } label: {
                if store.isRefreshing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(IconButtonStyle())
            .help("Refresh")

            Button {
                store.promptAddProjects()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(IconButtonStyle())
            .help("Add project…")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var headerSubtitle: String {
        if store.projects.isEmpty { return "Add a project to get started" }
        let n = store.attentionCount
        if n == 0 { return "All projects committed & pushed" }
        return "\(n) project\(n == 1 ? "" : "s") need\(n == 1 ? "s" : "") attention"
    }

    @ViewBuilder
    private var content: some View {
        if store.projects.isEmpty {
            emptyState
        } else if store.projects.count <= 6 {
            projectList
        } else {
            ScrollView { projectList }
                .frame(height: 440)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.primary.opacity(0.05))
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 24))
                    .foregroundStyle(Theme.magic)
            }
            .frame(width: 56, height: 56)
            VStack(spacing: 3) {
                Text("No projects yet").font(.system(size: 13, weight: .semibold))
                Text("Add git repositories to commit them with oco\nright from the menu bar.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                store.promptAddProjects()
            } label: {
                Label("Add Project", systemImage: "plus")
            }
            .buttonStyle(PillButtonStyle(fill: Theme.magic))
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }

    private var projectList: some View {
        VStack(spacing: 2) {
            ForEach(store.projects) { project in
                ProjectRow(project: project)
            }
        }
        .padding(6)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            LaunchAtLoginToggle()
            Spacer()
            if let last = store.lastRefresh {
                TimelineView(.periodic(from: .now, by: 15)) { _ in
                    Text("Updated \(last.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(IconButtonStyle())
            .keyboardShortcut("q")
            .help("Quit Magic Commit")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

// MARK: - Panel sizing

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// MenuBarExtra's window grows with its content but often fails to shrink
/// back, leaving empty space at the bottom. Force the window's content height
/// to match the SwiftUI content, keeping the top edge pinned under the menu bar.
private struct PanelHeightSync: NSViewRepresentable {
    var height: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let height = height
        DispatchQueue.main.async {
            guard height > 0, let window = view.window else { return }
            let content = window.contentRect(forFrameRect: window.frame)
            let delta = height - content.height
            guard abs(delta) > 0.5 else { return }
            var frame = window.frame
            frame.size.height += delta
            frame.origin.y -= delta
            window.setFrame(frame, display: true)
        }
    }
}

// MARK: - Row

struct ProjectRow: View {
    @EnvironmentObject private var store: ProjectStore
    let project: Project
    @State private var hovering = false
    @State private var showOutput = false

    private var status: GitStatus? { store.statuses[project.id] }
    private var activity: Activity? { store.activity[project.id] }
    private var log: ActionLog? { store.logs[project.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                statusIcon
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    detailLine
                }
                Spacer(minLength: 6)
                menu.opacity(hovering ? 1 : 0)
            }
            actions
            if let log { logView(log) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.snappy(duration: 0.25), value: status)
        .animation(.snappy(duration: 0.25), value: activity)
        .animation(.snappy(duration: 0.25), value: log)
        .contextMenu { menuItems }
    }

    // MARK: Status icon

    private var statusIcon: some View {
        let (symbol, tint): (String, Color) = {
            guard let status else { return ("circle.dotted", .secondary) }
            if status.error != nil { return ("exclamationmark.triangle.fill", .red) }
            if status.hasChanges { return ("pencil", .orange) }
            if status.canPush { return ("arrow.up", .blue) }
            return ("checkmark", .green)
        }()
        return ZStack {
            Circle().fill(tint.opacity(0.15))
            if activity != nil {
                ProgressView().controlSize(.small).scaleEffect(0.8)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 30, height: 30)
    }

    // MARK: Details

    @ViewBuilder
    private var detailLine: some View {
        if let activity {
            Text(activity.label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else if let status {
            if let error = status.error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            } else {
                HStack(spacing: 4) {
                    Chip(text: status.branch ?? "detached", systemImage: "arrow.triangle.branch", truncates: true)
                        .help(status.branch ?? "Detached HEAD")
                    if status.changes > 0 {
                        Chip(text: "\(status.changes)", systemImage: "pencil", tint: .orange)
                            .help("\(status.changes) changed file\(status.changes == 1 ? "" : "s")")
                    }
                    if status.wipCount > 0 {
                        Chip(text: "\(status.wipCount) WIP", systemImage: "bolt.fill", tint: .pink)
                            .help("\(status.wipCount) unpushed WIP commit\(status.wipCount == 1 ? "" : "s")")
                    }
                    if status.ahead > 0 {
                        Chip(text: "\(status.ahead)", systemImage: "arrow.up", tint: .blue)
                            .help("\(status.ahead) unpushed commit\(status.ahead == 1 ? "" : "s")")
                    }
                    if status.behind > 0 {
                        Chip(text: "\(status.behind)", systemImage: "arrow.down", tint: .purple)
                            .help("\(status.behind) commit\(status.behind == 1 ? "" : "s") behind upstream")
                    }
                }
            }
        } else {
            Text("Loading…")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Actions

    private var hasActions: Bool {
        guard activity == nil, let status, status.error == nil else { return false }
        return status.hasChanges || status.canPush || status.wipCount > 0
    }

    @ViewBuilder
    private var actions: some View {
        if hasActions, let status {
            HStack(spacing: 6) {
                if status.hasChanges {
                    Button {
                        store.commitWIP(project)
                    } label: {
                        Label("WIP", systemImage: "bolt.fill")
                    }
                    .buttonStyle(PillButtonStyle(fill: Color.primary.opacity(0.10), foreground: .primary, shadow: false))
                    .help("Quick commit with a \"WIP\" message (rename later with Batch oco)")

                    Button {
                        store.commit(project)
                    } label: {
                        Label("Commit", systemImage: "sparkles")
                    }
                    .buttonStyle(PillButtonStyle(fill: Theme.magic))
                    .help("Stage all changes and commit with oco")
                }
                if status.wipCount > 0 {
                    Button {
                        store.batchOco(project)
                    } label: {
                        Label("Batch oco · \(status.wipCount)", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(PillButtonStyle(fill: Theme.batch))
                    .help("Rename \(status.wipCount) unpushed WIP commit\(status.wipCount == 1 ? "" : "s") with oco-generated messages")
                }
                if status.canPush {
                    Button {
                        store.push(project)
                    } label: {
                        Label("Push", systemImage: "arrow.up")
                    }
                    .buttonStyle(PillButtonStyle(fill: Theme.push))
                    .help(status.upstream.map { "Push to \($0)" } ?? "Push and set upstream")
                }
            }
            .padding(.leading, 40)
            .transition(.opacity)
        }
    }

    private var menu: some View {
        Menu {
            menuItems
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Open in Finder") { NSWorkspace.shared.open(project.url) }
        Button("Open in Terminal") { openInTerminal() }
        Button("Refresh") { Task { await store.refresh(project) } }
        Divider()
        Button("Remove Project", role: .destructive) { store.remove(project) }
    }

    // MARK: Log

    private func logView(_ log: ActionLog) -> some View {
        let tint: Color = log.succeeded ? .green : .red
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: log.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(tint)
                Text(log.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if !log.output.isEmpty && log.succeeded {
                    Button(showOutput ? "Hide" : "Details") { showOutput.toggle() }
                        .buttonStyle(.link)
                }
                Button {
                    store.dismissLog(project)
                    showOutput = false
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Dismiss")
            }
            .font(.system(size: 11))

            if showOutput || (!log.succeeded && !log.output.isEmpty) {
                ScrollView {
                    Text(log.output)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 110)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.15)))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.10)))
        .padding(.leading, 40)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func openInTerminal() {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([project.url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}

struct Chip: View {
    var text: String
    var systemImage: String
    var tint: Color = .secondary
    /// Only the branch name may shrink; counts always stay readable.
    var truncates = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).font(.system(size: 8, weight: .bold))
            Text(text).font(.system(size: 10, weight: .medium)).lineLimit(1).truncationMode(.middle)
        }
        .fixedSize(horizontal: !truncates, vertical: true)
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.12)))
    }
}

// MARK: - Launch at login

struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled
    @State private var error: String?

    var body: some View {
        Toggle(isOn: Binding(
            get: { enabled },
            set: { newValue in
                do {
                    if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    error = nil
                } catch {
                    self.error = error.localizedDescription
                }
                enabled = SMAppService.mainApp.status == .enabled
            }
        )) {
            Text("Launch at login").font(.system(size: 11))
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .help(error ?? "Start Magic Commit when you log in")
    }
}
