import Testing
@testable import EDNCore

@Suite("Shortcut key normalization")
struct ShortcutKeyTests {
    @Test("Option-modified digits normalize from charactersIgnoringModifiers")
    func optionDigitRecordsDigit() {
        #expect(ShortcutKey.normalize("2") == "2")
    }

    @Test("Letters normalize to lowercase")
    func lettersNormalizeToLowercase() {
        #expect(ShortcutKey.normalize("A") == "a")
    }

    @Test("Composed characters are rejected")
    func composedCharactersAreRejected() {
        #expect(ShortcutKey.normalize("tm") == nil)
        #expect(ShortcutKey.normalize("™") == nil)
        #expect(ShortcutKey.normalize(nil) == nil)
    }
}
