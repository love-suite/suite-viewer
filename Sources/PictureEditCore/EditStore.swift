import CryptoKit
import Foundation

/// The editable version of a picture and the history that led to it, as the store keeps them.
public struct StoredEdits: Equatable {
    public var history: EditHistory
    /// Pictures placed on top, PNG data by asset name.
    public var assets: [String: Data]
    /// The version the picture file shows, when the edits were saved into it.
    public var saved: EditDocument?

    public init(history: EditHistory, assets: [String: Data] = [:], saved: EditDocument? = nil) {
        self.history = history
        self.assets = assets
        self.saved = saved
    }
}

/// Where the viewer keeps editable versions: in its own folder, never next to the picture, so the
/// picture stays a plain file that copies, mails and syncs as one (no sidecar file, no package, no
/// extended attribute riding along with copies).
///
/// Each picture gets a folder named by a random id, holding:
/// - `file.json`: which file it belongs to (path, volume and file number, SHA-256 of its content),
/// - `original.<ext>`: the picture as it was before the first edit, byte for byte,
/// - `edits.json`: the history of the editable version, the current state included, and the version
///   the file shows,
/// - `assets/<name>.png`: pictures placed on top.
///
/// A file is matched by its identity (volume and file number, which survive renaming and moving on
/// the same disk) or by its path, and only if its content is still what the viewer last saw: a
/// picture changed by another app starts afresh instead of showing stale edits.
public final class EditStore {
    public struct Record: Codable, Equatable, Sendable {
        public var id: String
        public var path: String
        public var volume: String?
        public var fileNumber: UInt64?
        /// SHA-256 of what the file holds now: the original until edits are saved, then the saved picture.
        public var contentHash: String
        /// The original's file name inside the entry's folder.
        public var originalFile: String
        public var created: Date
        public var modified: Date
    }

    public static let format = "explorer-picture-edits"

    public let folder: URL
    private let fileManager = FileManager.default

    public init(folder: URL) {
        self.folder = folder
    }

    /// `~/Library/Application Support/Explorer/Viewer/Edits`.
    public static var standard: EditStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return EditStore(folder: support.appendingPathComponent("Explorer/Viewer/Edits", isDirectory: true))
    }

    private func entryFolder(_ id: String) -> URL { folder.appendingPathComponent(id, isDirectory: true) }

    public func originalURL(_ record: Record) -> URL {
        entryFolder(record.id).appendingPathComponent(record.originalFile)
    }

    /// Every record, read from the entries' `file.json`.
    public func records() -> [Record] {
        let entries = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { entry in
            guard let data = try? Data(contentsOf: entry.appendingPathComponent("file.json")) else { return nil }
            return try? Self.decoder.decode(Record.self, from: data)
        }
    }

    /// The record of this file, if the viewer has edits for it and the file still holds what it saw.
    /// A file moved or renamed on the same disk is found again and its record follows it.
    public func record(for file: URL) -> Record? {
        let identity = FileFingerprint.identity(of: file)
        let path = file.standardizedFileURL.path
        let candidates = records().filter { record in
            (identity.fileNumber != nil && record.fileNumber == identity.fileNumber && record.volume == identity.volume)
                || record.path == path
        }
        guard !candidates.isEmpty, let hash = try? FileFingerprint.hash(of: file) else { return nil }
        guard var record = candidates.sorted(by: { $0.modified > $1.modified }).first(where: { $0.contentHash == hash })
        else { return nil }
        if record.path != path || record.fileNumber != identity.fileNumber || record.volume != identity.volume {
            record.path = path
            record.volume = identity.volume
            record.fileNumber = identity.fileNumber
            try? write(record)
        }
        return record
    }

    /// Starts keeping edits for a file: copies its original and records it. Older records of the same
    /// file (whose content has changed since) are removed.
    public func create(for file: URL) throws -> Record {
        let identity = FileFingerprint.identity(of: file)
        let path = file.standardizedFileURL.path
        for stale in records() where stale.path == path
            || (identity.fileNumber != nil && stale.fileNumber == identity.fileNumber && stale.volume == identity.volume) {
            try? remove(stale)
        }
        let id = UUID().uuidString
        let ext = file.pathExtension.isEmpty ? "" : "." + file.pathExtension.lowercased()
        let now = Date()
        let record = Record(id: id, path: path, volume: identity.volume, fileNumber: identity.fileNumber,
                            contentHash: try FileFingerprint.hash(of: file), originalFile: "original" + ext,
                            created: now, modified: now)
        try fileManager.createDirectory(at: entryFolder(id), withIntermediateDirectories: true)
        try fileManager.copyItem(at: file, to: originalURL(record))
        try write(record)
        return record
    }

    private func write(_ record: Record) throws {
        try Self.encoder.encode(record).write(to: entryFolder(record.id).appendingPathComponent("file.json"),
                                              options: .atomic)
    }

    private struct EditsFile: Codable {
        var format: String
        var version: Int
        var history: EditHistory
        var saved: EditDocument?
    }

    /// Saves the history and any asset not saved yet.
    public func save(_ edits: StoredEdits, for record: Record) throws {
        let entry = entryFolder(record.id)
        let file = EditsFile(format: Self.format, version: 1, history: edits.history, saved: edits.saved)
        try Self.encoder.encode(file).write(to: entry.appendingPathComponent("edits.json"), options: .atomic)
        if !edits.assets.isEmpty {
            let assets = entry.appendingPathComponent("assets", isDirectory: true)
            try fileManager.createDirectory(at: assets, withIntermediateDirectories: true)
            for (name, data) in edits.assets {
                let url = assets.appendingPathComponent(name + ".png")
                if !fileManager.fileExists(atPath: url.path) { try data.write(to: url, options: .atomic) }
            }
        }
        var record = record
        record.modified = Date()
        try write(record)
    }

    public func load(_ record: Record) throws -> StoredEdits {
        let entry = entryFolder(record.id)
        let file = try Self.decoder.decode(EditsFile.self, from: Data(contentsOf: entry.appendingPathComponent("edits.json")))
        var assets: [String: Data] = [:]
        let folder = entry.appendingPathComponent("assets", isDirectory: true)
        for url in (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "png" {
            assets[url.deletingPathExtension().lastPathComponent] = try? Data(contentsOf: url)
        }
        return StoredEdits(history: file.history, assets: assets, saved: file.saved)
    }

    /// After the viewer wrote the picture (flattened edits, or the original back): remembers its new
    /// content so the file is still recognised.
    @discardableResult
    public func fileWasWritten(_ file: URL, record: Record) throws -> Record {
        var record = record
        let identity = FileFingerprint.identity(of: file)
        record.path = file.standardizedFileURL.path
        record.volume = identity.volume
        record.fileNumber = identity.fileNumber
        record.contentHash = try FileFingerprint.hash(of: file)
        record.modified = Date()
        try write(record)
        return record
    }

    /// Forgets a picture's edits (its folder in the store, never the picture itself).
    public func remove(_ record: Record) throws {
        try fileManager.removeItem(at: entryFolder(record.id))
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// What identifies a file's content and the file itself.
public enum FileFingerprint {
    public static func hash(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The volume's UUID and the file's number on it: they stay the same when the file is renamed or
    /// moved on the same disk.
    public static func identity(of url: URL) -> (volume: String?, fileNumber: UInt64?) {
        let volume = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let number = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
        return (volume, number)
    }
}
