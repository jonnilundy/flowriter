import Foundation
import Security

/// A published version of Flowriter, read from the GitHub "latest release" feed.
public struct Release: Equatable, Sendable {
    public var tag: String
    public var version: [Int]
    /// The release notes without the download instructions the release page adds.
    public var notes: String
    public var page: URL
    /// The app zip; nil when the release has none.
    public var zip: URL?
}

public enum UpdateError: Error, Equatable, CustomStringConvertible {
    case feed(String)
    case noZip
    case download(String)
    case notAnApp
    case mismatch(String)
    case signature(String)
    case install(String)

    public var description: String {
        switch self {
        case let .feed(why): return "The release feed could not be read: \(why)"
        case .noZip: return "The release has no app to download."
        case let .download(why): return "The download failed: \(why)"
        case .notAnApp: return "The download holds no Flowriter.app."
        case let .mismatch(why): return "The download is not the expected app: \(why)"
        case let .signature(why): return "The download's signature does not check out: \(why)"
        case let .install(why): return "The new version could not be put in place: \(why)"
        }
    }
}

/// Check for a newer release, download it, check it, and swap it in after the app quits.
/// Nothing here runs on its own: Flowriter > Check for Updates starts it.
public enum Updates {
    public static let feedKey = "FlowriterUpdateFeed"
    public static let defaultFeed = URL(string: "https://api.github.com/repos/jonnilundy/flowriter/releases/latest")!

    /// The feed: `FlowriterUpdateFeed` when set (a URL, or a file path for tests), else GitHub.
    public static var feed: URL {
        guard let value = UserDefaults.standard.string(forKey: feedKey), !value.isEmpty else { return defaultFeed }
        return value.contains("://") ? URL(string: value) ?? defaultFeed : URL(fileURLWithPath: value)
    }

    // MARK: versions

    /// "v0.3.0" or "0.3.0" as [0, 3, 0]; nil for anything else.
    public static func version(_ text: String) -> [Int]? {
        let bare = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = bare.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return parts.map { $0! }
    }

    public static func isNewer(_ a: [Int], than b: [Int]) -> Bool {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    public static func display(_ v: [Int]) -> String { v.map(String.init).joined(separator: ".") }

    /// The running build's version; [0] for a build with no Info.plist (a command line run).
    public static var currentVersion: [Int] {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(version) ?? [0]
    }

    // MARK: feed

    public static func parse(_ data: Data) throws -> Release {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UpdateError.feed("not JSON") }
        guard let tag = json["tag_name"] as? String, let v = version(tag) else { throw UpdateError.feed("no version tag") }
        let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? URL(string: "https://github.com/jonnilundy/flowriter/releases")!
        let assets = json["assets"] as? [[String: Any]] ?? []
        let zip = assets.first { ($0["name"] as? String).map { $0.hasPrefix("Flowriter") && $0.hasSuffix(".zip") } ?? false }
            .flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }
        return Release(tag: tag, version: v, notes: notes(json["body"] as? String ?? ""), page: page, zip: zip)
    }

    /// The release notes up to the install instructions that scripts/release.sh appends.
    static func notes(_ body: String) -> String {
        var kept: [String] = []
        for paragraph in body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n") {
            let p = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if p.hasPrefix("**Not notarized") || p.hasPrefix("Download `") { continue }
            if !p.isEmpty { kept.append(p) }
        }
        return kept.joined(separator: "\n\n")
    }

    public static func latest() async throws -> Release {
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) } catch { throw UpdateError.feed(error.localizedDescription) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw UpdateError.feed("HTTP \(http.statusCode)") }
        return try parse(data)
    }

    // MARK: where the app is

    public enum Place: Equatable, Sendable {
        /// An app bundle in a folder this user can write: it can replace itself.
        case installable(URL)
        /// A command line build, not an app bundle.
        case notAnApp
        /// Run from a folder this user cannot write (or a disk image).
        case readOnly(URL)
        /// macOS runs a downloaded, never moved copy from a hidden read-only place.
        case translocated
    }

    public static func place(of bundle: URL) -> Place {
        guard bundle.pathExtension == "app" else { return .notAnApp }
        if bundle.path.contains("/AppTranslocation/") { return .translocated }
        let folder = bundle.deletingLastPathComponent().path
        return FileManager.default.isWritableFile(atPath: folder) && FileManager.default.isWritableFile(atPath: bundle.path)
            ? .installable(bundle) : .readOnly(bundle)
    }

    // MARK: download and check

    /// Download the release's zip into `folder`, unpack it and check the app in it against the
    /// running one. Returns the checked app.
    public static func stage(_ release: Release, current: URL, in folder: URL) async throws -> URL {
        guard let zipURL = release.zip else { throw UpdateError.noZip }
        let zip = folder.appendingPathComponent("Flowriter.zip")
        do {
            let (downloaded, response) = try await URLSession.shared.download(from: zipURL)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw UpdateError.download("HTTP \(http.statusCode)") }
            try? FileManager.default.removeItem(at: zip)
            try FileManager.default.moveItem(at: downloaded, to: zip)
        } catch let error as UpdateError { throw error } catch { throw UpdateError.download(error.localizedDescription) }
        let unpacked = folder.appendingPathComponent("unpacked")
        try? FileManager.default.removeItem(at: unpacked)
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]) == 0 else { throw UpdateError.download("the zip does not unpack") }
        let app = unpacked.appendingPathComponent("Flowriter.app")
        guard FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path) else { throw UpdateError.notAnApp }
        try verify(app, current: current, release: release)
        return app
    }

    /// The new app must be the same app (bundle id), the version the feed named, intact (its code
    /// signature checks out), and, when the running app is signed by a team, signed by the same team.
    public static func verify(_ app: URL, current: URL, release: Release) throws {
        // Info.plist read from disk each time: Bundle(url:) keeps the first one it saw for a path
        func info(_ app: URL) -> [String: Any]? { NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] }
        guard let new = info(app) else { throw UpdateError.notAnApp }
        let id = info(current)?["CFBundleIdentifier"] as? String ?? Bundle.main.bundleIdentifier
        guard new["CFBundleIdentifier"] as? String == id else {
            throw UpdateError.mismatch("bundle id \(new["CFBundleIdentifier"] as? String ?? "none"), expected \(id ?? "none")")
        }
        guard (new["CFBundleShortVersionString"] as? String).flatMap(version) == release.version else {
            throw UpdateError.mismatch("version \(new["CFBundleShortVersionString"] as? String ?? "none"), expected \(display(release.version))")
        }
        let newCode = try staticCode(app)
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(newCode, flags, nil)
        guard status == errSecSuccess else { throw UpdateError.signature(SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)") }
        if let team = teamID(try? staticCode(current)), teamID(newCode) != team {
            throw UpdateError.signature("signed by \(teamID(newCode) ?? "no team"), expected \(team)")
        }
    }

    private static func staticCode(_ url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw UpdateError.signature("unsigned (\(status))") }
        return code
    }

    private static func teamID(_ code: SecStaticCode?) -> String? {
        guard let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    // MARK: swap

    /// Waits up to 60 s for the app to quit, puts the new app in place of the old (the old one
    /// comes back when the move fails), reopens it, and removes the download folder.
    static let swapScript = """
    pid="$1"; new="$2"; dst="$3"; folder="$4"; relaunch="$5"; shift 5
    i=0
    while kill -0 "$pid" 2>/dev/null; do
      i=$((i + 1)); [ "$i" -gt 600 ] && { rm -rf "$folder"; exit 1; }
      sleep 0.1
    done
    old="$dst.previous"
    rm -rf "$old"
    mv "$dst" "$old" || { rm -rf "$folder"; exit 1; }
    if mv "$new" "$dst"; then rm -rf "$old"; else mv "$old" "$dst"; fi
    rm -rf "$folder"
    [ "$relaunch" = 1 ] && open "$dst" --args "$@"
    exit 0
    """

    /// Start the helper that swaps `new` into `destination` once process `pid` has quit. It
    /// outlives the app. `arguments` go to the reopened app.
    @discardableResult
    public static func swapAfterQuit(new: URL, into destination: URL, folder: URL, pid: Int32, relaunch: Bool, arguments: [String] = []) throws -> Process {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", swapScript, "flowriter-update", String(pid), new.path, destination.path, folder.path, relaunch ? "1" : "0"] + arguments
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do { try helper.run() } catch { throw UpdateError.install(error.localizedDescription) }
        return helper
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
