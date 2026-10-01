import Foundation

/// FloCore's resource bundle. In a signed .app the SwiftPM bundle lives in
/// Contents/Resources (codesign forbids extra items at the bundle root, where
/// `Bundle.module` looks first); elsewhere fall back to `Bundle.module`.
enum FloResources {
    static let bundle: Bundle = {
        if let res = Bundle.main.resourceURL?.appendingPathComponent("FloStateNative_FloCore.bundle"),
           let b = Bundle(url: res) { return b }
        return Bundle.module
    }()

    /// The folder holding the `<lang>.lproj` tables, as a bundle of its own. Localized lookups
    /// (`localizedString`, `preferredLocalizations`, `<lang>.lproj` paths) only see the top level of
    /// a bundle's resource directory. SwiftPM's native build made a flat bundle, where the copied
    /// `Resources/` folder is that directory; the Swift Build backend (default since Xcode 27) makes
    /// a `Contents/` bundle, which puts the folder one level down in `Contents/Resources/Resources`,
    /// so `bundle` alone has no localizations and every UI string stays English.
    static let strings: Bundle = {
        if let dir = bundle.url(forResource: "en", withExtension: "lproj", subdirectory: "Resources")?.deletingLastPathComponent(),
           let b = Bundle(url: dir) { return b }
        return bundle
    }()
}
