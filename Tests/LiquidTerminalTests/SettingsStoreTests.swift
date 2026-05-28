import Testing
import Foundation
@testable import LiquidTerminal

@MainActor
struct SettingsStoreTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func testFreshStoreReturnsDefaults() {
        let store = SettingsStore(userDefaults: makeDefaults())
        #expect(store.current == TerminalSettings.defaults)
    }

    @Test func testSavePersistsAcrossInstances() {
        let defaults = makeDefaults()
        let store = SettingsStore(userDefaults: defaults)
        store.current.cols = 123
        store.save()

        let reopened = SettingsStore(userDefaults: defaults)
        #expect(reopened.current.cols == 123)
    }

    @Test func testCorruptDataFallsBackToDefaults() {
        let defaults = makeDefaults()
        defaults.set("not json".data(using: .utf8), forKey: SettingsStore.storageKey)
        let store = SettingsStore(userDefaults: defaults)
        #expect(store.current == TerminalSettings.defaults)
    }

    @Test func testResetToDefaults() {
        let defaults = makeDefaults()
        let store = SettingsStore(userDefaults: defaults)
        store.current.cols = 200
        store.save()
        store.resetToDefaults()
        #expect(store.current == TerminalSettings.defaults)

        // resetToDefaults persists, so a freshly-opened store also reads defaults.
        let reopened = SettingsStore(userDefaults: defaults)
        #expect(reopened.current == TerminalSettings.defaults)
    }

    @Test func testSaveClampsBeforePersisting() {
        let defaults = makeDefaults()
        let store = SettingsStore(userDefaults: defaults)
        store.current.cols = 99999
        store.save()
        let reopened = SettingsStore(userDefaults: defaults)
        #expect(reopened.current.cols == TerminalSettings.colsRange.upperBound)
    }
}
