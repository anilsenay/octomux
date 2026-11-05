import XCTest

extension XCTestCase {
    /// A UserDefaults suite for this test alone. When the test ends its keys and its file in ~/Library/Preferences
    /// go (removing the keys alone leaves an empty plist behind for every run).
    func scratchDefaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { removeTestSuite(name) }
        return d
    }
}

func removeTestSuite(_ name: String) {
    UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
    let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(name).plist")
    try? FileManager.default.removeItem(at: file)
}
