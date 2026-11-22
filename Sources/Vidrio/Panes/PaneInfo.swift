import Foundation

/// Read-only facts about what a pane's shell is doing.
enum PaneInfo {
    /// The current directory of a running process.
    static func workingDirectory(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    /// The git branch of `directory`, read from `.git/HEAD` without spawning git. A detached
    /// HEAD reports its short hash. Worktrees and submodules use a `.git` file pointing at
    /// the real directory.
    static func gitBranch(forDirectory directory: String, fileManager: FileManager = .default) -> String? {
        var current = URL(fileURLWithPath: directory).standardizedFileURL
        while true {
            let dotGit = current.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                var gitDir = dotGit
                if !isDirectory.boolValue {
                    guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                          text.hasPrefix("gitdir:") else { return nil }
                    let target = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                    gitDir = URL(fileURLWithPath: target, relativeTo: current).standardizedFileURL
                }
                guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
                else { return nil }
                return parseHead(head)
            }
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { return nil }
            current = parent
        }
    }

    static func parseHead(_ head: String) -> String? {
        let text = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("ref: refs/heads/") { return String(text.dropFirst("ref: refs/heads/".count)) }
        return text.isEmpty ? nil : String(text.prefix(7))
    }

    /// Parses `lsof -nP -iTCP -sTCP:LISTEN -Fpn` into listening ports per process.
    static func parseListeningPorts(lsofOutput: String) -> [pid_t: [Int]] {
        var result: [pid_t: Set<Int>] = [:]
        var pid: pid_t?
        for line in lsofOutput.split(separator: "\n") {
            guard let kind = line.first else { continue }
            let value = line.dropFirst()
            if kind == "p" {
                pid = pid_t(value)
            } else if kind == "n", let pid, let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...]) {
                result[pid, default: []].insert(port)
            }
        }
        return result.mapValues { $0.sorted() }
    }

    /// Parses `ps -axo pid=,ppid=` into a child-to-parent map.
    static func parseParents(psOutput: String) -> [pid_t: pid_t] {
        var result: [pid_t: pid_t] = [:]
        for line in psOutput.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            if parts.count == 2, let pid = pid_t(parts[0]), let parent = pid_t(parts[1]) {
                result[pid] = parent
            }
        }
        return result
    }

    /// Assigns each listening port to the shell its process descends from.
    static func ports(forShells shells: Set<pid_t>, listening: [pid_t: [Int]], parents: [pid_t: pid_t]) -> [pid_t: [Int]] {
        var result: [pid_t: Set<Int>] = [:]
        for (pid, ports) in listening {
            var current = pid
            var steps = 0
            while steps < 64 {
                if shells.contains(current) {
                    result[current, default: []].formUnion(ports)
                    break
                }
                guard let parent = parents[current], parent > 1 else { break }
                current = parent
                steps += 1
            }
        }
        return result.mapValues { $0.sorted() }
    }

    /// Blocking: runs `lsof` and `ps`, so call it off the main thread.
    static func listeningPorts(forShells shells: Set<pid_t>) -> [pid_t: [Int]] {
        guard !shells.isEmpty,
              let lsof = run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"]),
              let ps = run("/bin/ps", ["-axo", "pid=,ppid="]) else { return [:] }
        return ports(
            forShells: shells,
            listening: parseListeningPorts(lsofOutput: lsof),
            parents: parseParents(psOutput: ps)
        )
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
