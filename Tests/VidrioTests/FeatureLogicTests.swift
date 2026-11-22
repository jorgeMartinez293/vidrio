import Testing
import Foundation
@testable import Vidrio

struct TerminalNotificationParserTests {
    @Test func testOSC9() {
        #expect(TerminalNotificationParser.parseOSC9("Build done") == TerminalMessage(title: nil, body: "Build done"))
        #expect(TerminalNotificationParser.parseOSC9("") == nil)
        #expect(TerminalNotificationParser.parseOSC9("4;1;50") == nil)
        #expect(TerminalNotificationParser.parseOSC9("Note; with semicolon")?.body == "Note; with semicolon")
    }

    @Test func testOSC777() {
        #expect(TerminalNotificationParser.parseOSC777("notify;Title;Body; more")
            == TerminalMessage(title: "Title", body: "Body; more"))
        #expect(TerminalNotificationParser.parseOSC777("notify;Only") == TerminalMessage(title: nil, body: "Only"))
        #expect(TerminalNotificationParser.parseOSC777("other;a;b") == nil)
    }

    @Test func testKittyChunks() {
        var assembler = KittyNotificationAssembler()
        #expect(assembler.feed("i=1:d=0:p=title;Hello") == nil)
        #expect(assembler.feed("i=1:p=body;World") == TerminalMessage(title: "Hello", body: "World"))
        #expect(assembler.feed(";Plain") == TerminalMessage(title: nil, body: "Plain"))
        #expect(assembler.feed("e=1;SGk=") == TerminalMessage(title: nil, body: "Hi"))
    }
}

struct AgentHooksTests {
    @Test func testParsesReports() {
        #expect(AgentStateReport.parse("working\n") == AgentStateReport(state: .working))
        // Hook scripts installed by an earlier version add a second line.
        #expect(AgentStateReport.parse("done\nabc\n") == AgentStateReport(state: .done))
        #expect(AgentStateReport.parse("ended\n") == AgentStateReport(state: nil))
        #expect(AgentStateReport.parse("nonsense\n") == nil)
    }

    @Test func testMergeKeepsOtherHooksAndRemoveRestoresThem() throws {
        let existing: [String: Any] = [
            "model": "opus",
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "my-hook"]]]]],
        ]
        let merged = AgentHooks.merged(existing, scriptPath: "/x/vidrio-agent-state")
        #expect(AgentHooks.isInstalled(in: merged))
        let stop = (merged["hooks"] as? [String: Any])?["Stop"] as? [Any]
        #expect(stop?.count == 2)
        #expect((AgentHooks.merged(merged, scriptPath: "/x/vidrio-agent-state")["hooks"] as? [String: Any])?["Stop"]
            .flatMap { ($0 as? [Any])?.count } == 2)

        let removed = AgentHooks.removed(merged)
        #expect(!AgentHooks.isInstalled(in: removed))
        #expect(removed["model"] as? String == "opus")
        let hooks = removed["hooks"] as? [String: Any]
        #expect(hooks?.count == 1)
        #expect((hooks?["Stop"] as? [Any])?.count == 1)
        #expect(AgentHooks.removed(AgentHooks.merged([:], scriptPath: "/x/vidrio-agent-state")).isEmpty)
    }

    @Test func testInstallBacksUpAndRefusesBrokenJSON() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("vidrio-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let settings = dir.appendingPathComponent("settings.json")
        let script = dir.appendingPathComponent("bin/vidrio-agent-state")

        try #"{"model":"opus"}"#.write(to: settings, atomically: true, encoding: .utf8)
        try AgentHooks.install(settingsFile: settings, scriptFile: script)
        #expect(AgentHooks.isInstalled(in: try AgentHooks.readSettings(at: settings)))
        #expect(fm.isExecutableFile(atPath: script.path))
        #expect(try String(contentsOf: dir.appendingPathComponent("settings.json.vidrio-backup"), encoding: .utf8)
            == #"{"model":"opus"}"#)

        try "{broken".write(to: settings, atomically: true, encoding: .utf8)
        #expect(throws: AgentHooks.HookError.self) {
            try AgentHooks.install(settingsFile: settings, scriptFile: script)
        }
        #expect(try String(contentsOf: settings, encoding: .utf8) == "{broken")
    }
}

struct PromptMarksTests {
    @Test func testNavigation() {
        var marks = PromptMarks()
        [10, 20, 30].forEach { marks.add($0) }
        #expect(marks.previous(before: 25) == 20)
        #expect(marks.previous(before: 10) == nil)
        #expect(marks.next(after: 20) == 30)
        #expect(marks.next(after: 30) == nil)
    }

    @Test func testRedrawReplacesLaterMarksAndPruneDropsTrimmed() {
        var marks = PromptMarks()
        [10, 20, 30].forEach { marks.add($0) }
        marks.add(20)
        #expect(marks.rows == [10, 20])
        marks.prune(below: 15)
        #expect(marks.rows == [20])
    }
}

struct LinkDetectorTests {
    private func link(_ text: String, at needle: String) -> DetectedLink? {
        let offset = text.distance(from: text.startIndex, to: text.range(of: needle)!.lowerBound)
        return LinkDetector.link(in: text, atOffset: offset)
    }

    @Test func testURLs() {
        #expect(link("see https://example.com/a?b=1, ok", at: "example") == .url("https://example.com/a?b=1"))
        #expect(link("(https://en.wikipedia.org/wiki/Foo_(bar))", at: "wiki") == .url("https://en.wikipedia.org/wiki/Foo_(bar)"))
    }

    @Test func testFiles() {
        #expect(link("error in Sources/main.swift:42:7: boom", at: "main") == .file(path: "Sources/main.swift", line: 42, column: 7))
        #expect(link("open README.md now", at: "README") == .file(path: "README.md", line: nil, column: nil))
        #expect(link("~/notes/todo.txt", at: "todo") == .file(path: "~/notes/todo.txt", line: nil, column: nil))
    }

    @Test func testPlainWordsAreNotLinks() {
        #expect(link("hello world", at: "world") == nil)
        #expect(LinkDetector.link(in: "a b", atOffset: 1) == nil)
    }

    @Test func testPolicyBlocksDangerousSchemes() {
        #expect(LinkPolicy.allowsURL("https://example.com"))
        #expect(LinkPolicy.allowsURL("mailto:a@example.com"))
        #expect(!LinkPolicy.allowsURL("javascript:alert(1)"))
        #expect(!LinkPolicy.allowsURL("x-apple.systempreferences:foo"))
        #expect(!LinkPolicy.allowsURL("file:///System/Applications/Calculator.app"))
    }

    @Test func testPolicyBlocksRunnableFiles() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("vidrio-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let note = dir.appendingPathComponent("note.txt")
        let command = dir.appendingPathComponent("run.command")
        let binary = dir.appendingPathComponent("tool")
        for file in [note, command, binary] { try Data("x".utf8).write(to: file) }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        #expect(LinkPolicy.allowsFile(atPath: note.path))
        #expect(!LinkPolicy.allowsFile(atPath: command.path))
        #expect(!LinkPolicy.allowsFile(atPath: binary.path))
    }

    @Test func testEditorCommandQuotesPath() {
        let command = LinkPolicy.editorCommand(template: "code -g {file}:{line}:{column}", path: "/tmp/a'; rm -rf x", line: 3, column: nil)
        #expect(command == "code -g '/tmp/a'\\''; rm -rf x':3:1")
    }
}

struct PaneInfoTests {
    @Test func testParseHead() {
        #expect(PaneInfo.parseHead("ref: refs/heads/feature/x\n") == "feature/x")
        #expect(PaneInfo.parseHead("f9033b9abcdef\n") == "f9033b9")
    }

    @Test func testGitBranchWalksUpAndFollowsWorktrees() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("vidrio-tests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let nested = dir.appendingPathComponent("repo/a/b")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        let git = dir.appendingPathComponent("repo/.git")
        try fm.createDirectory(at: git, withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        #expect(PaneInfo.gitBranch(forDirectory: nested.path) == "main")

        let worktree = dir.appendingPathComponent("wt")
        let real = dir.appendingPathComponent("repo/.git/worktrees/wt")
        try fm.createDirectory(at: worktree, withIntermediateDirectories: true)
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try "ref: refs/heads/topic\n".write(to: real.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "gitdir: \(real.path)\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        #expect(PaneInfo.gitBranch(forDirectory: worktree.path) == "topic")
    }

    @Test func testPortsReachTheirShell() {
        let listening = PaneInfo.parseListeningPorts(lsofOutput: "p300\nf5\nn*:3000\nn127.0.0.1:3000\np400\nf6\nn[::1]:8080\n")
        #expect(listening == [300: [3000], 400: [8080]])
        let parents = PaneInfo.parseParents(psOutput: "  300   200\n  200   100\n  400     1\n")
        #expect(PaneInfo.ports(forShells: [100], listening: listening, parents: parents) == [100: [3000]])
    }

    @Test func testWorkingDirectoryOfThisProcess() {
        let expected = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path
        let actual = PaneInfo.workingDirectory(pid: getpid()).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        #expect(actual == expected)
    }
}

struct KeyBindingTests {
    @Test func testParseAndFormat() {
        let combo = KeyCombo("shift+cmd+P")
        #expect(combo?.command == true && combo?.shift == true && combo?.key == "p")
        #expect(combo?.text == "shift+cmd+p")
        #expect(combo?.symbol == "⇧⌘P")
        #expect(KeyCombo("cmd+") == nil)
        #expect(KeyCombo("hyper+p") == nil)
        #expect(KeyBinding("ctrl+b c")?.isChord == true)
        #expect(KeyBinding("a b c") == nil)
    }

    @Test func testDefaultsAreValidAndUnique() {
        let bindings = ShortcutAction.allCases.compactMap { $0.binding(overrides: [:])?.text }
        #expect(Set(bindings).count == bindings.count)
        for action in ShortcutAction.allCases where !action.defaultBinding.isEmpty {
            #expect(KeyBinding(action.defaultBinding) != nil)
        }
    }

    @Test func testOverrides() {
        #expect(ShortcutAction.find.binding(overrides: ["find": "cmd+e"])?.text == "cmd+e")
        #expect(ShortcutAction.find.binding(overrides: ["find": ""]) == nil)
        #expect(ShortcutAction.find.binding(overrides: ["find": "nonsense+key"])?.text == "cmd+f")
    }

    @Test func testChordMatcher() {
        var matcher = ChordMatcher(bindings: [("split", KeyBinding("ctrl+b c")!), ("plain", KeyBinding("cmd+k")!)])
        #expect(matcher.handle(KeyCombo("cmd+k")!) == .ignored)
        #expect(matcher.handle(KeyCombo("ctrl+b")!) == .pending)
        #expect(matcher.handle(KeyCombo("c")!) == .fired("split"))
        #expect(matcher.handle(KeyCombo("ctrl+b")!) == .pending)
        #expect(matcher.handle(KeyCombo("x")!) == .cancelled)
        #expect(matcher.handle(KeyCombo("x")!) == .ignored)
    }
}

struct GreeterPaletteTests {
    @Test func testFollowsSprite() {
        let accent = SpriteColor(red: 255, green: 120, blue: 200)
        let palette = TerminalPalette.matching(accent: accent)
        #expect(TerminalPalette.swiftTermColors(palette)?.count == 16)
        // Red stays recognizably red.
        let red = SpriteColor(hex: palette[1])!
        #expect(red.red > red.green && red.red > red.blue)
        // Blue moves most of the way to the sprite's color.
        let blue = SpriteColor(hex: palette[4])!
        #expect(abs(Int(blue.red) - Int(accent.red)) < 80)
    }

    @Test func testStandardPaletteIsComplete() {
        #expect(TerminalPalette.swiftTermColors(TerminalPalette.standard)?.count == 16)
    }
}

struct PaneNavigationTests {
    @Test func testRowCoversEveryPaneAndWraps() {
        let columns = [[0, 3], [1], [2, 4]]
        var visited = [0]
        for _ in 0..<4 { visited.append(GridLayout.neighborInRow(of: visited.last!, offset: 1, columns: columns)) }
        #expect(visited == [0, 3, 1, 2, 4])
        #expect(GridLayout.neighborInRow(of: 4, offset: 1, columns: columns) == 0)
        #expect(GridLayout.neighborInRow(of: 0, offset: -1, columns: columns) == 4)
    }
}

struct LinkRangeTests {
    @Test func testRangesCoverTheWholeLink() {
        let text = "see (https://example.com/a), then main.swift:42:7 now"
        let url = LinkDetector.match(in: text, atOffset: 10)
        #expect(url?.range == 5..<26)
        let file = LinkDetector.match(in: text, atOffset: 36)
        #expect(file?.range == 34..<49)
    }

    @Test func testHyperlinkPayload() {
        #expect(LinkDetector.hyperlinkURL(payload: ";https://example.com") == "https://example.com")
        #expect(LinkDetector.hyperlinkURL(payload: "id=1;https://example.com/a;b") == "https://example.com/a;b")
        #expect(LinkDetector.hyperlinkURL(payload: "nonsense") == nil)
    }

    @Test func testOnlyOpenableLinksCount() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("vidrio-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("note.txt"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("run.command"))
        #expect(LinkPolicy.canOpen(.file(path: "note.txt", line: 2, column: nil), workingDirectory: dir.path))
        #expect(!LinkPolicy.canOpen(.file(path: "missing.txt", line: nil, column: nil), workingDirectory: dir.path))
        #expect(!LinkPolicy.canOpen(.file(path: "run.command", line: nil, column: nil), workingDirectory: dir.path))
        #expect(LinkPolicy.canOpen(.url("https://example.com"), workingDirectory: nil))
        #expect(!LinkPolicy.canOpen(.url("javascript:alert(1)"), workingDirectory: nil))
    }
}

struct WorkspaceAndSettingsTests {
    @Test func testWorkspaceList() {
        var list = WorkspaceList()
        let main = list.active
        let second = list.add(name: "  API  ")
        #expect(second.name == "API")
        #expect(list.neighbor(offset: 1).id == second.id)
        #expect(list.neighbor(offset: -1).id == second.id)
        list.activate(second.id)
        list.rename(second.id, to: "Backend")
        #expect(list.active.name == "Backend")
        list.remove(second.id)
        #expect(list.activeID == main.id)
        list.remove(main.id)
        #expect(list.workspaces.count == 1)
    }

    @Test func testNewSettingsDefaultOnOldFiles() throws {
        let old = try JSONDecoder().decode(TerminalSettings.self, from: Data(#"{"cols": 80, "themeName": "Nord"}"#.utf8))
        #expect(!old.matchGreeterColors)
        #expect(old.ringColor == nil)
        #expect(old.clipboardAccess == .ask)
        #expect(!old.quickTerminalEnabled)
        let future = try JSONDecoder().decode(TerminalSettings.self, from: Data(#"{"clipboardAccess": "someday"}"#.utf8))
        #expect(future.clipboardAccess == .ask)
    }

    @Test func testRingColorRoundTrips() throws {
        var settings = TerminalSettings.defaults
        settings.ringColor = RGBAColor(red: 1, green: 0, blue: 0.5, alpha: 1)
        settings.matchGreeterColors = true
        let decoded = try JSONDecoder().decode(TerminalSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }
}

struct FuzzyMatcherTests {
    @Test func testMatching() {
        #expect(FuzzyMatcher.score(query: "npn", in: "New Pane") != nil)
        #expect(FuzzyMatcher.score(query: "xyz", in: "New Pane") == nil)
        #expect(FuzzyMatcher.score(query: "", in: "New Pane") == 0)
    }

    @Test func testPrefersWordStarts() {
        let wordStart = FuzzyMatcher.score(query: "zp", in: "Zoom Pane")!
        let scattered = FuzzyMatcher.score(query: "zp", in: "Lazy Dropdown")!
        #expect(wordStart > scattered)
    }
}
