import Foundation

/// Whether the writing tools (hints, alternatives decorations, view toggles) are on.
/// Flipped by clicking the word count. Persisted in UserDefaults.
public enum WritingTools {
    public static let didChange = Notification.Name("WritingToolsDidChange")
    private static let key = "FlowriterWritingToolsOn"
    public static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set {
            guard newValue != isOn else { return }
            UserDefaults.standard.set(newValue, forKey: key)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
}
