import Foundation

/// One-time cleanup for machines that ran the old standalone sereno installer: its `.zshrc`
/// block calls a `sereno_greet` shell function that no longer exists now that the greeter
/// renders natively, so left in place it would print "command not found" on every new shell.
///
/// The block is matched by its first and last lines because real-world installs vary in
/// between (e.g. `%F{white}` vs `%F{15}` in the PROMPT line, depending on install.sh vintage).
/// That also means anything a user added inside it goes too, so the original file is always
/// backed up first.
enum LegacySerenoCleanup {
    private static let firstLine = "# sereno"
    private static let lastLine = "sereno_greet"

    /// `contents` without the sereno block, or nil if it has none. Works on whole lines, so
    /// the lines around the block stay separate.
    static func stripped(_ contents: String) -> String? {
        var lines = contents.components(separatedBy: "\n")
        guard let first = lines.firstIndex(of: firstLine),
              let last = lines[(first + 1)...].firstIndex(of: lastLine)
        else { return nil }
        lines.removeSubrange(first...last)
        return lines.joined(separator: "\n")
    }

    /// Removes the block from `rcFile`, writing through a symlink rather than replacing it
    /// (dotfile managers rely on the link) and keeping the file's permissions. The backup
    /// sits next to `rcFile`, not next to the link's target, to stay out of dotfile repos.
    /// Leaves the file untouched if the backup fails. Returns whether it changed the file.
    @discardableResult
    static func run(on rcFile: URL, fileManager: FileManager = .default) -> Bool {
        let target = rcFile.resolvingSymlinksInPath()
        guard let contents = try? String(contentsOf: target, encoding: .utf8),
              let cleaned = stripped(contents)
        else { return false }
        do {
            try fileManager.copyItem(at: target, to: unusedBackupURL(for: rcFile, fileManager))
            let permissions = try fileManager.attributesOfItem(atPath: target.path)[.posixPermissions]
            try cleaned.write(to: target, atomically: true, encoding: .utf8)
            if let permissions {
                try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
            }
            return true
        } catch {
            return false
        }
    }

    private static func unusedBackupURL(for rcFile: URL, _ fileManager: FileManager) -> URL {
        let directory = rcFile.deletingLastPathComponent()
        let base = rcFile.lastPathComponent + ".vidrio-backup"
        var candidate = directory.appendingPathComponent(base)
        var suffix = 1
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base).\(suffix)")
            suffix += 1
        }
        return candidate
    }
}
