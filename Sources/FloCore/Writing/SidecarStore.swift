import CryptoKit
import Foundation

/// How a load went.
public enum SidecarLoadStatus: Equatable, Sendable {
    /// No sidecar file: an empty sidecar.
    case missing
    case loaded
    /// The file could not be read as a sidecar. It was copied to `backup` and an empty sidecar
    /// is returned; the next save replaces the broken file.
    case recoveredFromCorrupt(backup: URL)
    /// The file comes from a newer schema. It was copied to `backup` (like a corrupt file).
    case newerSchema(version: Int, backup: URL)
}

/// An item whose anchor could not be found again on load (it is in `sidecar.unresolved`).
public struct UnresolvedAnchorReport: Equatable, Sendable {
    public enum Kind: String, Sendable { case alternative, ghost }
    public var kind: Kind
    public var id: String
    public var quote: String
    public var reason: AnchorFailure
}

public struct SidecarLoadResult: Equatable, Sendable {
    public var sidecar: DocumentSidecar
    public var status: SidecarLoadStatus
    /// Anchors found at another place than stored (document edited outside the app).
    public var moved: [String]
    /// Anchors that could not be found.
    public var unresolved: [UnresolvedAnchorReport]
}

public enum SidecarSaveOutcome: Equatable, Sendable {
    case written
    /// The sidecar became empty and the old file was removed.
    case removed
    /// Nothing stored and no file on disk: nothing written.
    case skipped
}

/// Load and save `.<name>.flowriter.json` next to a document.
public enum SidecarStore {
    public static let fileSuffix = ".flowriter.json"

    /// `/dir/post.md` -> `/dir/.post.md.flowriter.json`
    public static func url(for documentURL: URL) -> URL {
        let name = documentURL.lastPathComponent
        return documentURL.deletingLastPathComponent().appendingPathComponent("." + name + fileSuffix)
    }

    public static func backupURL(for documentURL: URL) -> URL {
        url(for: documentURL).appendingPathExtension("bak")
    }

    /// Read the sidecar of `documentURL` and anchor it in `documentText` (the text the editor
    /// shows). Never throws: a missing file gives an empty sidecar, a broken one is backed up.
    public static func load(for documentURL: URL, documentText: String) -> SidecarLoadResult {
        let file = url(for: documentURL)
        guard let data = FileManager.default.contents(atPath: file.path) else {
            return SidecarLoadResult(sidecar: DocumentSidecar(), status: .missing, moved: [], unresolved: [])
        }
        let decoded: SidecarCodec.Decoded
        do {
            decoded = try SidecarCodec.decode(data)
        } catch let SidecarCodec.DecodeError.newerSchema(v) {
            let bak = backUp(file, for: documentURL)
            return SidecarLoadResult(sidecar: DocumentSidecar(), status: .newerSchema(version: v, backup: bak), moved: [], unresolved: [])
        } catch {
            let bak = backUp(file, for: documentURL)
            return SidecarLoadResult(sidecar: DocumentSidecar(), status: .recoveredFromCorrupt(backup: bak), moved: [], unresolved: [])
        }
        var result = anchor(decoded.sidecar, in: documentText, storedHash: decoded.documentSHA256)
        result.status = .loaded
        return result
    }

    /// Find every stored anchor in `text`. Items that fail go to `unresolved` (with their old
    /// selector); earlier unresolved items get another try.
    public static func anchor(_ stored: DocumentSidecar, in text: String, storedHash: String?) -> SidecarLoadResult {
        let units = Array(text.utf16)
        let unchanged = storedHash != nil && storedHash == sha256(text)
        var out = DocumentSidecar(overflow: stored.overflow)
        var moved: [String] = [], failed: [UnresolvedAnchorReport] = []

        for var set in stored.alternatives + stored.unresolved.alternatives {
            switch set.anchor.resolve(in: units, documentUnchanged: unchanged) {
            case let .exact(a): set.anchor = a; out.alternatives.append(set)
            case let .moved(a): set.anchor = a; out.alternatives.append(set); moved.append(set.id)
            case let .failed(why):
                out.unresolved.alternatives.append(set)
                failed.append(UnresolvedAnchorReport(kind: .alternative, id: set.id, quote: set.anchor.quote, reason: why))
            }
        }
        for var g in stored.ghosts + stored.unresolved.ghosts {
            switch g.anchor.resolve(in: units, documentUnchanged: unchanged) {
            case let .exact(a): g.anchor = a; out.ghosts.append(g)
            case let .moved(a): g.anchor = a; out.ghosts.append(g); moved.append(g.id)
            case let .failed(why):
                out.unresolved.ghosts.append(g)
                failed.append(UnresolvedAnchorReport(kind: .ghost, id: g.id, quote: g.anchor.quote, reason: why))
            }
        }
        return SidecarLoadResult(sidecar: out, status: .loaded, moved: moved, unresolved: failed)
    }

    /// Write the sidecar for `documentURL` (atomic). `documentText` is the text being saved to
    /// the .md: selectors are refreshed from it. An empty sidecar writes nothing and removes a
    /// stale file.
    @discardableResult
    public static func save(_ sidecar: DocumentSidecar, for documentURL: URL, documentText: String) throws -> SidecarSaveOutcome {
        let file = url(for: documentURL)
        let fm = FileManager.default
        if sidecar.isEmpty {
            guard fm.fileExists(atPath: file.path) else { return .skipped }
            try fm.removeItem(at: file)
            return .removed
        }
        let data = SidecarCodec.encode(sidecar.refreshed(in: documentText), documentText: documentText)
        if let old = fm.contents(atPath: file.path), old == data { return .written }
        try data.write(to: file, options: .atomic)
        return .written
    }

    public static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Copy a bad file to `.bak` (replacing an older backup). Returns the backup URL.
    @discardableResult
    static func backUp(_ file: URL, for documentURL: URL) -> URL {
        let bak = backupURL(for: documentURL)
        let fm = FileManager.default
        try? fm.removeItem(at: bak)
        try? fm.copyItem(at: file, to: bak)
        return bak
    }
}

extension DocumentSidecar {
    /// Selectors taken from `text`, and each alternative set's current variant text set to the
    /// text its anchor covers (the writer may have typed inside it).
    public func refreshed(in text: String) -> DocumentSidecar {
        let units = Array(text.utf16)
        var s = self
        for i in s.alternatives.indices {
            s.alternatives[i].anchor = s.alternatives[i].anchor.refreshed(in: units)
            let covered = s.alternatives[i].anchor.quote
            if let v = s.alternatives[i].variants.firstIndex(where: { $0.id == s.alternatives[i].currentId }),
               s.alternatives[i].variants[v].text != covered {
                s.alternatives[i].variants[v].text = covered
            }
        }
        for i in s.ghosts.indices { s.ghosts[i].anchor = s.ghosts[i].anchor.refreshed(in: units) }
        return s
    }
}

/// JSON encoding of the sidecar (format in DocumentSidecar.swift).
public enum SidecarCodec {
    public enum DecodeError: Error, Equatable {
        case notJSON(String)
        case missing(String)
        case invalid(String)
        case newerSchema(Int)
    }

    public struct Decoded: Equatable, Sendable {
        public var sidecar: DocumentSidecar
        public var documentSHA256: String?
    }

    public static func encode(_ s: DocumentSidecar, documentText: String) -> Data {
        var top: [(String, JSONValue)] = [
            ("schemaVersion", .int(Int64(DocumentSidecar.schemaVersion))),
            ("documentSHA256", .string(SidecarStore.sha256(documentText))),
            ("alternatives", .array(s.alternatives.map(alternative))),
            ("ghosts", .array(s.ghosts.map(ghost))),
            ("overflow", .array(s.sortedOverflow.map(overflow))),
        ]
        if !s.unresolved.isEmpty {
            top.append(("unresolved", .object([
                ("alternatives", .array(s.unresolved.alternatives.map(alternative))),
                ("ghosts", .array(s.unresolved.ghosts.map(ghost))),
            ])))
        }
        return Data((JSON.prettyString(.object(top)) + "\n").utf8)
    }

    public static func decode(_ data: Data) throws -> Decoded {
        let root: JSONValue
        do { root = try JSON.parse(data: data) } catch { throw DecodeError.notJSON("\(error)") }
        guard root.objectValue != nil else { throw DecodeError.invalid("top level is not an object") }
        guard let v = root["schemaVersion"]?.intValue else { throw DecodeError.missing("schemaVersion") }
        if v > Int64(DocumentSidecar.schemaVersion) { throw DecodeError.newerSchema(Int(v)) }
        guard v == 1 else { throw DecodeError.invalid("schemaVersion \(v)") }
        var s = DocumentSidecar()
        s.alternatives = try list(root["alternatives"], "alternatives").map(alternative)
        s.ghosts = try list(root["ghosts"], "ghosts").map(ghost)
        s.overflow = try list(root["overflow"], "overflow").map(overflow)
        if let u = root["unresolved"], !u.isNull {
            s.unresolved.alternatives = try list(u["alternatives"], "unresolved.alternatives").map(alternative)
            s.unresolved.ghosts = try list(u["ghosts"], "unresolved.ghosts").map(ghost)
        }
        return Decoded(sidecar: s, documentSHA256: root["documentSHA256"]?.stringValue)
    }

    // MARK: Encode

    static func anchor(_ a: TextAnchor) -> JSONValue {
        .object([("from", .int(Int64(a.from))), ("to", .int(Int64(a.to))), ("quote", .string(a.quote)),
                 ("prefix", .string(a.prefix)), ("suffix", .string(a.suffix))])
    }

    static func alternative(_ s: AlternativeSet) -> JSONValue {
        .object([("id", .string(s.id)), ("level", .string(s.level.rawValue)), ("anchor", anchor(s.anchor)),
                 ("originalId", .string(s.originalId)), ("currentId", .string(s.currentId)),
                 ("variants", .array(s.variants.map { v in
                     .object([("id", .string(v.id)), ("text", .string(v.text)), ("author", .string(v.author.rawValue)),
                              ("createdAt", .string(date(v.createdAt)))])
                 }))])
    }

    static func ghost(_ g: GhostRecord) -> JSONValue {
        var pairs: [(String, JSONValue)] = [("id", .string(g.id)), ("anchor", anchor(g.anchor)), ("author", .string(g.author.rawValue)),
                                            ("state", .string(g.state.rawValue)), ("createdAt", .string(date(g.createdAt)))]
        if let src = g.source { pairs.append(("source", .string(src))) }
        return .object(pairs)
    }

    static func overflow(_ o: OverflowItem) -> JSONValue {
        .object([("id", .string(o.id)), ("text", .string(o.text)), ("createdAt", .string(date(o.createdAt))), ("order", .int(Int64(o.order)))])
    }

    // MARK: Decode

    static func list(_ v: JSONValue?, _ name: String) throws -> [JSONValue] {
        guard let v, !v.isNull else { return [] }
        guard let a = v.arrayValue else { throw DecodeError.invalid("\(name) is not an array") }
        return a
    }

    static func str(_ o: JSONValue, _ key: String) throws -> String {
        guard let s = o[key]?.stringValue else { throw DecodeError.missing(key) }
        return s
    }

    static func int(_ o: JSONValue, _ key: String) throws -> Int {
        guard let i = o[key]?.intValue else { throw DecodeError.missing(key) }
        return Int(i)
    }

    static func enumValue<E: RawRepresentable>(_ o: JSONValue, _ key: String) throws -> E where E.RawValue == String {
        guard let e = E(rawValue: try str(o, key)) else { throw DecodeError.invalid("\(key) = \(o[key].map(JSON.prettyString) ?? "")") }
        return e
    }

    static func dateValue(_ o: JSONValue, _ key: String) throws -> Date {
        let s = try str(o, key)
        guard let d = parseDate(s) else { throw DecodeError.invalid("\(key) = \(s)") }
        return d
    }

    static func anchor(_ o: JSONValue) throws -> TextAnchor {
        guard let a = o["anchor"], a.objectValue != nil else { throw DecodeError.missing("anchor") }
        let f = try int(a, "from"), t = try int(a, "to")
        guard f >= 0, t >= f else { throw DecodeError.invalid("anchor \(f)..<\(t)") }
        return TextAnchor(from: f, to: t, quote: try str(a, "quote"),
                          prefix: a["prefix"]?.stringValue ?? "", suffix: a["suffix"]?.stringValue ?? "")
    }

    static func alternative(_ o: JSONValue) throws -> AlternativeSet {
        let variants = try list(o["variants"], "variants").map { v in
            AlternativeVariant(id: try str(v, "id"), text: try str(v, "text"), author: try enumValue(v, "author"),
                               createdAt: try dateValue(v, "createdAt"))
        }
        let set = AlternativeSet(id: try str(o, "id"), level: try enumValue(o, "level"), anchor: try anchor(o),
                                 variants: variants, originalId: try str(o, "originalId"), currentId: try str(o, "currentId"))
        guard set.current != nil else { throw DecodeError.invalid("currentId \(set.currentId) is not a variant") }
        guard set.original != nil else { throw DecodeError.invalid("originalId \(set.originalId) is not a variant") }
        return set
    }

    static func ghost(_ o: JSONValue) throws -> GhostRecord {
        GhostRecord(id: try str(o, "id"), anchor: try anchor(o), author: try enumValue(o, "author"), state: try enumValue(o, "state"),
                   createdAt: try dateValue(o, "createdAt"), source: o["source"]?.stringValue)
    }

    static func overflow(_ o: JSONValue) throws -> OverflowItem {
        OverflowItem(id: try str(o, "id"), text: try str(o, "text"), createdAt: try dateValue(o, "createdAt"), order: try int(o, "order"))
    }

    // MARK: Dates

    static func date(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s).map(SidecarClock.truncate)
    }
}
