import Foundation

/// Flowriter: this fork's identity, kept in one file so upstream merges stay easy.
/// A distinct bundle id, app-data folder, CLI name and single-instance channel mean the fork
/// can sit next to upstream Flo State without either one replacing, forwarding to, or
/// sharing sessions with the other. Updates come from the fork's own Sparkle feed (appcast.xml in
/// this repo, signed with the fork's own EdDSA key), never from upstream's.
public enum ForkIdentity {
    public static let appName = "Flowriter"
    public static let bundleID = "app.flowriter.Flowriter"
    /// The bundle id of builds before the rename. Its defaults move over once (DefaultsMigration).
    public static let legacyBundleID = "com.jonnilundy.flowriter"
    /// Folder under ~/Library/Application Support (upstream: "FloStateNative").
    public static let dataDirName = "Flowriter"
    /// Distributed notification used to hand paths to an already running copy.
    public static let openNotificationName = "app.flowriter.Flowriter.open"
    /// `/usr/local/bin/<cliName>` symlink (upstream: "flostate").
    public static let cliName = "flowriter"
    /// Sparkle runs only in a bundle built by scripts/bundle.sh that carries a real SUPublicEDKey
    /// (AppUpdater.isConfigured): not tests, a bare binary, or a build made before the key exists.
    public static let updatesEnabled = true
    /// Upstream makes itself the default Markdown / plain-text app on first launch from
    /// /Applications. The fork leaves the user's default apps alone.
    public static let claimsDefaultTextHandlers = false
}

/// Flowriter: a one-time copy of the defaults that builds before the rename wrote under
/// `ForkIdentity.legacyBundleID`. The only compatibility rule for the old id.
public enum DefaultsMigration {
    public static let doneKey = "FlowriterMigrated"

    /// When `defaults` has no `doneKey` and `oldDomain` has values: copy every key of `oldDomain`
    /// into `defaults`, then set `doneKey`. True when it copied.
    @discardableResult
    public static func run(from oldDomain: String = ForkIdentity.legacyBundleID, into defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: doneKey) == nil,
              let old = defaults.persistentDomain(forName: oldDomain), !old.isEmpty else { return false }
        for (key, value) in old { defaults.set(value, forKey: key) }
        defaults.set(true, forKey: doneKey)
        return true
    }
}
