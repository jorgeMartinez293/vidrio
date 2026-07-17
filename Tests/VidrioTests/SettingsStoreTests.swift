import Testing
import Foundation
@testable import Vidrio

@MainActor
struct SettingsStoreTests {
    private func makeFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vidrio-tests-\(UUID().uuidString)")
            .appendingPathComponent("settings.json")
    }

    /// Empty defaults suite so tests never see (or migrate) a real legacy install.
    private func makeDefaults() -> UserDefaults {
        let suite = "test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func testFreshStoreReturnsDefaults() {
        let store = SettingsStore(fileURL: makeFileURL(), legacyDefaults: makeDefaults())
        #expect(store.current == TerminalSettings.defaults)
    }

    @Test func testSavePersistsAcrossInstances() {
        let url = makeFileURL()
        let store = SettingsStore(fileURL: url, legacyDefaults: makeDefaults())
        store.current.cols = 123
        store.save()

        let reopened = SettingsStore(fileURL: url, legacyDefaults: makeDefaults())
        #expect(reopened.current.cols == 123)
    }

    @Test func testCorruptDataFallsBackToDefaults() throws {
        let url = makeFileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let store = SettingsStore(fileURL: url, legacyDefaults: makeDefaults())
        #expect(store.current == TerminalSettings.defaults)
    }

    @Test func testResetToDefaults() {
        let url = makeFileURL()
        let store = SettingsStore(fileURL: url, legacyDefaults: makeDefaults())
        store.current.cols = 200
        store.save()
        store.resetToDefaults()
        #expect(store.current == TerminalSettings.defaults)

        // resetToDefaults persists, so a freshly-opened store also reads defaults.
        let reopened = SettingsStore(fileURL: url, legacyDefaults: makeDefaults())
        #expect(reopened.current == TerminalSettings.defaults)
    }

    @Test func testSaveClampsBeforePersisting() {
        let url = makeFileURL()
        let store = SettingsStore(fileURL: url, legacyDefaults: makeDefaults())
        store.current.cols = 99999
        store.save()
        let reopened = SettingsStore(fileURL: url, legacyDefaults: makeDefaults())
        #expect(reopened.current.cols == TerminalSettings.colsRange.upperBound)
    }

    @Test func testMigratesLegacyUserDefaults() throws {
        let url = makeFileURL()
        let defaults = makeDefaults()
        var legacy = TerminalSettings.defaults
        legacy.cols = 77
        defaults.set(try JSONEncoder().encode(legacy), forKey: SettingsStore.legacyStorageKey)

        let store = SettingsStore(fileURL: url, legacyDefaults: defaults)
        #expect(store.current.cols == 77)
        // Migration wrote the file: a reopen without the legacy defaults still sees it.
        let reopened = SettingsStore(fileURL: url, legacyDefaults: makeDefaults())
        #expect(reopened.current.cols == 77)
    }
}
