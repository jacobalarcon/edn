import Foundation

public enum ShortcutKey {
    public static let allowedCharacters = "0123456789abcdefghijklmnopqrstuvwxyz"

    public static func normalize(_ charactersIgnoringModifiers: String?) -> String? {
        let value = charactersIgnoringModifiers?.lowercased() ?? ""
        guard value.count == 1,
              let character = value.first,
              allowedCharacters.contains(character) else {
            return nil
        }
        return String(character)
    }
}
