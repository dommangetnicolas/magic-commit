import Foundation

/// Headless commands, e.g.
///   "Magic Commit.app/Contents/MacOS/MagicCommit" batch-oco /path/to/repo
enum CLI {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard args.count >= 3, args[1] == "batch-oco" else { return }
        let path = (args[2] as NSString).expandingTildeInPath

        let done = DispatchSemaphore(value: 0)
        var code: Int32 = 0
        Task.detached {
            let status = await Git.status(at: path)
            guard let branch = status.branch, status.error == nil else {
                FileHandle.standardError.write(Data("\(status.error ?? "Not on a branch")\n".utf8))
                code = 1
                done.signal()
                return
            }
            let result = await Git.batchOco(at: path, branch: branch) { current, total in
                print("Renaming WIP \(current)/\(total)…")
            }
            if result.succeeded {
                print(result.stdout)
            } else {
                FileHandle.standardError.write(Data((result.combinedOutput + "\n").utf8))
                code = 1
            }
            done.signal()
        }
        done.wait()
        exit(code)
    }
}
