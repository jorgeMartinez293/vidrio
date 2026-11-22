import Testing
import Foundation
@testable import Vidrio

struct LegacySerenoCleanupTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vidrio-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func testKeepsSurroundingLinesSeparate() {
        let input = "export A=1\n# sereno\nPROMPT=x\nsereno_greet\nalias b=c\n"
        #expect(LegacySerenoCleanup.stripped(input) == "export A=1\nalias b=c\n")
    }

    @Test func testHandlesBlockAtFileEdges() {
        #expect(LegacySerenoCleanup.stripped("# sereno\nsereno_greet\nnext\n") == "next\n")
        #expect(LegacySerenoCleanup.stripped("first\n# sereno\nsereno_greet") == "first")
    }

    @Test func testIgnoresFilesWithoutACompleteBlock() {
        #expect(LegacySerenoCleanup.stripped("a\nb\n") == nil)
        #expect(LegacySerenoCleanup.stripped("# sereno\nno end\n") == nil)
        #expect(LegacySerenoCleanup.stripped("sereno_greet\n# sereno\n") == nil)
    }

    @Test func testWritesThroughSymlinkAndBacksUp() throws {
        let fm = FileManager.default
        let dir = try makeDirectory()
        defer { try? fm.removeItem(at: dir) }
        let real = dir.appendingPathComponent("dotfiles-zshrc")
        let link = dir.appendingPathComponent(".zshrc")
        let original = "a\n# sereno\nmine\nsereno_greet\nb\n"
        try original.write(to: real, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path)
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        #expect(LegacySerenoCleanup.run(on: link))

        #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == real.path)
        #expect(try String(contentsOf: real, encoding: .utf8) == "a\nb\n")
        let permissions = try fm.attributesOfItem(atPath: real.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        let backup = dir.appendingPathComponent(".zshrc.vidrio-backup")
        #expect(try String(contentsOf: backup, encoding: .utf8) == original)
        #expect(!LegacySerenoCleanup.run(on: link))
    }

    @Test func testNeverOverwritesAnEarlierBackup() throws {
        let fm = FileManager.default
        let dir = try makeDirectory()
        defer { try? fm.removeItem(at: dir) }
        let rc = dir.appendingPathComponent(".zshrc")
        let earlier = dir.appendingPathComponent(".zshrc.vidrio-backup")
        try "earlier".write(to: earlier, atomically: true, encoding: .utf8)
        try "# sereno\nsereno_greet\n".write(to: rc, atomically: true, encoding: .utf8)

        #expect(LegacySerenoCleanup.run(on: rc))

        #expect(try String(contentsOf: earlier, encoding: .utf8) == "earlier")
        #expect(fm.fileExists(atPath: earlier.path + ".1"))
    }
}

struct ProcessLaunchTests {
    private func withFile(
        _ bytes: [UInt8], permissions: Int, _ body: (String) throws -> Void
    ) throws {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("vidrio-tests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: url) }
        try Data(bytes).write(to: url)
        try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        try body(url.path)
    }

    @Test func testLoginArgv0() {
        #expect(ShellLaunch.loginArgv0(forShell: "/bin/zsh") == "-zsh")
        #expect(ShellLaunch.loginArgv0(forShell: "/opt/homebrew/bin/fish") == "-fish")
    }

    @Test func testBinaryRunsDirectly() {
        #expect(ScriptLaunch.resolve(path: "/bin/ls") == ScriptLaunch(executable: "/bin/ls", args: []))
    }

    @Test func testExecutableShebangRunsDirectly() throws {
        try withFile(Array("#!/usr/bin/env python3\n".utf8), permissions: 0o755) { path in
            #expect(ScriptLaunch.resolve(path: path) == ScriptLaunch(executable: path, args: []))
        }
    }

    @Test func testNonExecutableScriptUsesBash() throws {
        try withFile(Array("#!/bin/sh\n".utf8), permissions: 0o644) { path in
            #expect(ScriptLaunch.resolve(path: path) == ScriptLaunch(executable: "/bin/bash", args: [path]))
        }
    }

    @Test func testExecutableWithoutShebangUsesBash() throws {
        try withFile(Array("echo hi\n".utf8), permissions: 0o755) { path in
            #expect(ScriptLaunch.resolve(path: path) == ScriptLaunch(executable: "/bin/bash", args: [path]))
        }
    }

    @Test func testDecodesWaitStatus() {
        #expect(ProcessExit(waitStatus: 0) == .exited(0))
        #expect(ProcessExit(waitStatus: 0).isSuccess)
        #expect(ProcessExit(waitStatus: 126 << 8) == .exited(126))
        #expect(!ProcessExit(waitStatus: 126 << 8).isSuccess)
        #expect(ProcessExit(waitStatus: 9) == .signaled(9))
        #expect(ProcessExit(waitStatus: nil) == .unknown)
    }
}

struct CloseConfirmationTests {
    @Test func testNamesDistinctPrograms() {
        #expect(CloseConfirmation.informativeText(for: ["claude"])
            == "“claude” is still running and will be stopped.")
        #expect(CloseConfirmation.informativeText(for: ["claude", "claude"])
            == "“claude” is still running and will be stopped.")
        #expect(CloseConfirmation.informativeText(for: ["a", "b", "c"])
            == "“a”, “b” and “c” are still running and will be stopped.")
        #expect(CloseConfirmation.informativeText(for: ["a", "b", "c", "d", "e"])
            == "“a”, “b”, “c” and 2 more are still running and will be stopped.")
    }
}

struct ScrollbackTests {
    @Test func testSettingDefaultsAndClamps() throws {
        let old = try JSONDecoder().decode(TerminalSettings.self, from: Data(#"{"cols": 80}"#.utf8))
        #expect(old.scrollbackLines == TerminalSettings.defaultScrollbackLines)
        let high = try JSONDecoder().decode(
            TerminalSettings.self, from: Data(#"{"scrollbackLines": 99999999}"#.utf8)
        )
        #expect(high.scrollbackLines == TerminalSettings.scrollbackRange.upperBound)
    }

    @Test func testThumbTracksPosition() {
        #expect(ScrollIndicatorView.thumbOriginY(position: 1, trackHeight: 100, thumbHeight: 20) == 0)
        #expect(ScrollIndicatorView.thumbOriginY(position: 0, trackHeight: 100, thumbHeight: 20) == 80)
        #expect(ScrollIndicatorView.thumbOriginY(position: 0.5, trackHeight: 100, thumbHeight: 20) == 40)
    }
}
