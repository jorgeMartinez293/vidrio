import Foundation

/// How to start the user's interactive shell.
enum ShellLaunch {
    /// `argv[0]` that makes a shell run as a login shell: its name with a leading dash. Login
    /// shells read `.zprofile` and, on macOS, run `path_helper`, which an app started from
    /// Finder needs because it inherits only a minimal environment.
    static func loginArgv0(forShell path: String) -> String {
        "-" + URL(fileURLWithPath: path).lastPathComponent
    }
}

/// How to run a file vidrio was asked to open.
struct ScriptLaunch: Equatable {
    let executable: String
    let args: [String]

    /// Files the kernel can execute (a binary, or a script with a shebang) run directly, so
    /// they get the interpreter they asked for. Anything else is handed to bash.
    static func resolve(path: String, fileManager: FileManager = .default) -> ScriptLaunch {
        isDirectlyExecutable(path, fileManager)
            ? ScriptLaunch(executable: path, args: [])
            : ScriptLaunch(executable: "/bin/bash", args: [path])
    }

    /// Mach-O and universal binary magic numbers, in both byte orders.
    private static let binaryMagics: Set<UInt32> = [
        0xFEEDFACE, 0xFEEDFACF, 0xCEFAEDFE, 0xCFFAEDFE,
        0xCAFEBABE, 0xCAFEBABF, 0xBEBAFECA, 0xBFBAFECA,
    ]

    private static func isDirectlyExecutable(_ path: String, _ fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isExecutableFile(atPath: path),
              let handle = FileHandle(forReadingAtPath: path)
        else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4), header.count >= 2 else { return false }
        if header.starts(with: [0x23, 0x21]) { return true } // "#!"
        guard header.count == 4 else { return false }
        return binaryMagics.contains(header.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
    }
}

/// How a child process ended, decoded from the raw `waitpid` status SwiftTerm reports.
enum ProcessExit: Equatable {
    case exited(Int32)
    case signaled(Int32)
    case unknown

    init(waitStatus: Int32?) {
        guard let waitStatus else {
            self = .unknown
            return
        }
        let signal = waitStatus & 0x7F
        self = signal == 0 ? .exited((waitStatus >> 8) & 0xFF) : .signaled(signal)
    }

    var isSuccess: Bool { self == .exited(0) }

    var summary: String {
        switch self {
        case .exited(let code): return "Process exited with code \(code)"
        case .signaled(let signal): return "Process terminated by signal \(signal)"
        case .unknown: return "Process ended"
        }
    }
}
