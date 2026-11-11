import Foundation

struct ShellResult {
    var status: Int32
    var stdout: String
    var stderr: String

    var succeeded: Bool { status == 0 }

    /// stdout + stderr, ANSI codes stripped, for display.
    var combinedOutput: String {
        [stdout, stderr]
            .map { Shell.stripANSI($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

enum Shell {
    /// Environment used for every child process. GUI apps don't inherit the
    /// user's shell PATH (nvm, Homebrew…), so resolve it once from an
    /// interactive login shell.
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let fallback = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        if let path = resolveShellPath() {
            env["PATH"] = path
        } else {
            env["PATH"] = ((env["PATH"]?.split(separator: ":").map(String.init) ?? []) + fallback).joined(separator: ":")
        }
        // Dev/testing aid: prepend directories (e.g. a fake `oco`) to the resolved PATH.
        if let extra = env["MAGIC_COMMIT_EXTRA_PATH"], !extra.isEmpty {
            env["PATH"] = extra + ":" + (env["PATH"] ?? "")
        }
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["NO_COLOR"] = "1"
        env["FORCE_COLOR"] = "0"
        env["TERM"] = "dumb"
        return env
    }()

    private static func userShell() -> String {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            let s = String(cString: sh)
            if !s.isEmpty { return s }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    private static func resolveShellPath() -> String? {
        let marker = "__MAGIC_COMMIT_PATH__"
        let result = runSync(
            executable: userShell(),
            arguments: ["-ilc", "printf '\(marker)%s\(marker)' \"$PATH\""],
            directory: nil,
            environment: ProcessInfo.processInfo.environment,
            timeout: 10
        )
        let parts = result.stdout.components(separatedBy: marker)
        guard parts.count >= 3 else { return nil }
        let path = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Runs `arguments` (resolved via PATH) in `directory`.
    static func run(
        _ arguments: [String],
        in directory: String,
        extraEnvironment: [String: String] = [:],
        timeout: TimeInterval? = nil
    ) async -> ShellResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let env = environment.merging(extraEnvironment) { _, new in new }
                let result = runSync(
                    executable: "/usr/bin/env",
                    arguments: arguments,
                    directory: directory,
                    environment: env,
                    timeout: timeout
                )
                continuation.resume(returning: result)
            }
        }
    }

    private static func runSync(
        executable: String,
        arguments: [String],
        directory: String?,
        environment: [String: String],
        timeout: TimeInterval?
    ) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ShellResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }

        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
        }

        // Drain stderr concurrently so a full pipe can't deadlock the child.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        return ShellResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }
}
