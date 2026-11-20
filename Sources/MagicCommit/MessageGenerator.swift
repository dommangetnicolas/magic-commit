import Foundation

/// The tool that writes commit messages: OpenCommit (`oco`), or the local Claude Code (`claude`)
/// or OpenCode (`opencode`) CLI.
enum MessageGenerator: String, CaseIterable, Identifiable, Sendable {
    case oco
    case claude
    case opencode

    static let defaultsKey = "messageGenerator"

    var id: String { rawValue }

    /// The generator picked in the menu (OpenCommit until changed).
    static var current: MessageGenerator {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(MessageGenerator.init) ?? .oco }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    var displayName: String {
        switch self {
        case .oco: return "OpenCommit (oco)"
        case .claude: return "Claude Code (claude)"
        case .opencode: return "OpenCode (opencode)"
        }
    }

    /// Short name used in progress labels.
    var shortName: String { rawValue }

    /// Commits the staged changes with a generated message.
    /// `extraEnvironment` is passed to the commit (e.g. GIT_AUTHOR_* when replaying).
    func commit(at path: String, extraEnvironment: [String: String] = [:]) async -> ShellResult {
        switch self {
        case .oco:
            // --yes skips the confirmation prompt; OCO_GITPUSH=false skips the push prompt
            // (pushing is a separate button).
            let env = extraEnvironment.merging(["OCO_GITPUSH": "false"]) { _, new in new }
            return Self.explainMissing(await Shell.run(["oco", "--yes"], in: path, extraEnvironment: env, timeout: 300), tool: "oco")
        case .claude:
            return await Self.llmCommit(at: path, tool: "claude", extraEnvironment: extraEnvironment) { input in
                let generated = await Shell.run(
                    ["claude", "-p", Self.prompt,
                     "--model", Self.claudeModel,
                     "--tools", "",
                     "--no-session-persistence",
                     "--output-format", "text"],
                    in: path,
                    input: input,
                    timeout: 300
                )
                return (generated, generated.stdout)
            }
        case .opencode:
            return await Self.llmCommit(at: path, tool: "opencode", extraEnvironment: extraEnvironment) { input in
                var arguments = ["opencode", "run", "--format", "json", "--archived", "--title", "Magic Commit"]
                if let model = Self.opencodeModel { arguments += ["--model", model] }
                arguments.append(Self.prompt)
                let generated = await Shell.run(arguments, in: path, input: input, timeout: 300)
                let parsed = Self.opencodeText(generated.stdout)
                if let error = parsed.error, generated.status != 127 {
                    return (ShellResult(status: 1, stdout: "", stderr: "opencode failed: \(error)\n\(generated.stderr)"), "")
                }
                return (generated, parsed.text)
            }
        }
    }

    // MARK: Claude

    /// Model alias passed to `claude --model`. Override with
    /// `defaults write io.github.dommangetnicolas.MagicCommit claudeModel sonnet`.
    static var claudeModel: String {
        let value = UserDefaults.standard.string(forKey: "claudeModel")?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? "haiku" : value
    }

    /// Diffs longer than this are cut (the `--stat` summary above it still lists every file).
    static let maxDiffCharacters = 120_000

    // MARK: OpenCode

    /// Model passed to `opencode run --model` (`provider/model`); OpenCode's own default when unset. Set with
    /// `defaults write io.github.dommangetnicolas.MagicCommit opencodeModel anthropic/claude-haiku-4-5`.
    static var opencodeModel: String? {
        let value = UserDefaults.standard.string(forKey: "opencodeModel")?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? nil : value
    }

    /// The final answer from `opencode run --format json` output (one JSON event per line):
    /// the text parts of the last assistant message, so text written around tool calls is skipped.
    /// `error` is set when the run reported an `error` event.
    static func opencodeText(_ output: String) -> (text: String, error: String?) {
        var order: [String] = []
        var texts: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = event["type"] as? String
            else { continue }
            if type == "error" {
                let error = event["error"] as? [String: Any]
                return ("", (error?["message"] as? String) ?? "unknown error")
            }
            guard type == "text", let part = event["part"] as? [String: Any],
                  let text = part["text"] as? String
            else { continue }
            let message = part["messageID"] as? String ?? ""
            if texts[message] == nil { order.append(message) }
            texts[message, default: ""] += text
        }
        return (order.last.flatMap { texts[$0] } ?? "", nil)
    }

    // MARK: Shared by Claude and OpenCode

    /// Sends the staged diff and recent commit subjects to `generate` (which runs `tool` and returns its
    /// result plus the message text), then commits the cleaned message.
    private static func llmCommit(
        at path: String,
        tool: String,
        extraEnvironment: [String: String],
        generate: (_ input: String) async -> (result: ShellResult, text: String)
    ) async -> ShellResult {
        let stat = await Shell.run(["git", "diff", "--cached", "--no-color", "--stat"], in: path)
        guard stat.succeeded else { return stat }
        guard !stat.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ShellResult(status: 1, stdout: "", stderr: "Nothing staged to commit.")
        }
        let patch = await Shell.run(["git", "diff", "--cached", "--no-color", "--no-ext-diff"], in: path)
        guard patch.succeeded else { return patch }
        var diff = patch.stdout
        if diff.count > maxDiffCharacters {
            diff = String(diff.prefix(maxDiffCharacters)) + "\n[… diff truncated …]\n"
        }

        let log = await Shell.run(["git", "log", "-15", "--no-merges", "--format=%s"], in: path)
        let recent = log.stdout.split(separator: "\n").map(String.init).filter { !Git.isWIP($0) }.prefix(10)

        let input = """
        Recent commit subjects in this repository:
        \(recent.isEmpty ? "(none)" : recent.map { "- \($0)" }.joined(separator: "\n"))

        Staged changes (summary):
        \(stat.stdout)
        Staged changes (diff):
        \(diff)
        """

        let (generated, text) = await generate(input)
        guard generated.succeeded else { return explainMissing(generated, tool: tool) }
        guard let message = cleanMessage(text) else {
            return ShellResult(status: 1, stdout: "", stderr: "\(tool) returned an empty commit message.\n\n\(generated.combinedOutput)")
        }
        return await Shell.run(["git", "commit", "-F", "-"], in: path, extraEnvironment: extraEnvironment, input: message, timeout: 300)
    }

    static let prompt = """
    You write git commit messages. The input on stdin lists recent commit subjects \
    from the repository, then the staged changes. Write the commit message for the \
    staged changes.

    Rules:
    - If the recent subjects follow a consistent style (e.g. Conventional Commits, \
    capitalized imperative sentences, a ticket prefix), follow that style. Otherwise \
    use Conventional Commits (feat:, fix:, refactor:, docs:, chore:, test:…).
    - Subject line: imperative mood, at most 72 characters, no trailing period.
    - Add a body (after a blank line) only when the change needs explaining; wrap it \
    at 72 characters and say why, not just what.
    - Output only the commit message: no preamble, no quotes, no code fences.
    """

    /// Strips code fences, surrounding quotes and blank lines from the model's answer.
    static func cleanMessage(_ raw: String) -> String? {
        var lines = Shell.stripANSI(raw).components(separatedBy: .newlines)
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        var text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2, let first = text.first, first == text.last, first == "\"" || first == "`" {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text + "\n"
    }

    /// `/usr/bin/env` exits with 127 when the tool isn't on the PATH.
    private static func explainMissing(_ result: ShellResult, tool: String) -> ShellResult {
        guard result.status == 127 else { return result }
        let hint: String
        switch tool {
        case "claude": hint = "Install Claude Code (https://claude.com/claude-code) and sign in once with `claude` in a terminal."
        case "opencode": hint = "Install OpenCode (https://opencode.ai) and connect a provider once with `opencode auth login` in a terminal."
        default: hint = "Install OpenCommit with `npm install -g opencommit`, or switch to Claude Code or OpenCode in the menu."
        }
        return ShellResult(status: 127, stdout: "", stderr: "`\(tool)` wasn't found on your PATH. \(hint)")
    }
}
