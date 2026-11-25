import SuiteCore
import Foundation
import SuiteFilesCore

/// A file of the folder the viewer steps through, with what sorting looks at.
public struct FolderFile: Hashable, Sendable, SortableFile {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    /// A directory shown as a single file, such as an .app bundle.
    public let isPackage: Bool
    public let size: Int64?
    public let modified: Date?
    /// The localized type shown in Explorer's Type column.
    public let kind: String?

    public var isFolder: Bool { isDirectory && !isPackage }

    public init(url: URL, name: String, isDirectory: Bool = false, isPackage: Bool = false, size: Int64? = nil,
                modified: Date? = nil, kind: String? = nil) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.size = size
        self.modified = modified
        self.kind = kind
    }
}

/// A folder's files in the order Explorer shows them (its view options, `FolderViewStore`), so the viewer's
/// arrow keys follow that order.
public enum FolderFiles {
    static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey,
                                         .localizedTypeDescriptionKey]

    public static func item(at url: URL) -> FolderFile {
        let values = try? url.resourceValues(forKeys: Set(keys))
        return FolderFile(url: url, name: url.lastPathComponent, isDirectory: values?.isDirectory ?? false,
                          isPackage: values?.isPackage ?? false, size: values?.fileSize.map(Int64.init),
                          modified: values?.contentModificationDate, kind: values?.localizedTypeDescription)
    }

    /// The folder's visible files; the Trash shows all its folders at once (home, iCloud Drive, disks), as
    /// in Explorer.
    public static func load(_ folder: URL) throws -> [FolderFile] {
        var urls: [URL] = []
        let folders = folder.standardizedFileURL == TrashLocations.url.standardizedFileURL ? TrashLocations.all : [folder]
        for (index, folder) in folders.enumerated() {
            do {
                urls += try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                    options: [.skipsHiddenFiles])
            } catch where index > 0 {
                // The Trash's other folders may be missing; the home one's error (Full Disk Access) is passed on.
                continue
            }
        }
        return urls.map(item(at:))
    }

    /// The folder's files sorted as Explorer shows the folder.
    public static func sorted(_ folder: URL, store: FolderViewStore = .shared) -> [FolderFile] {
        let options = store.options(for: folder)
        return FileSorter.sorted((try? load(folder)) ?? [], by: options.sortKey, ascending: options.ascending)
    }
}
