import Foundation
import UniformTypeIdentifiers
import SuiteCore

/// The pictures of a folder, in the folder's order, and the one being shown: what the viewer steps
/// through with the arrow keys. Like Windows' Photos, it wraps around at both ends.
public struct PictureSequence: Equatable {
    public private(set) var urls: [URL]
    public private(set) var index: Int

    /// Pictures among `items` (already sorted as the folder is), starting at `current`.
    public init(items: [FolderFile], current: URL) {
        let pictures = items.filter { !$0.isDirectory && Self.isPicture($0.url) }.map(\.url)
        let path = current.standardizedFileURL.path
        if let found = pictures.firstIndex(where: { $0.standardizedFileURL.path == path }) {
            urls = pictures
            index = found
        } else {
            // Shown on its own, for instance a picture the folder listing doesn't include.
            urls = [current]
            index = 0
        }
    }

    public static func isPicture(_ url: URL) -> Bool { ViewerApp.showsPicture(url) }

    public var current: URL? { urls.isEmpty ? nil : urls[index] }
    public var isEmpty: Bool { urls.isEmpty }

    /// "3 of 12".
    public var position: String { "\(index + 1) of \(urls.count)" }

    public mutating func next() {
        guard !urls.isEmpty else { return }
        index = (index + 1) % urls.count
    }

    public mutating func previous() {
        guard !urls.isEmpty else { return }
        index = (index - 1 + urls.count) % urls.count
    }

    /// After the current picture was deleted: the next one shows, or the previous one at the end.
    public mutating func removeCurrent() {
        guard !urls.isEmpty else { return }
        urls.remove(at: index)
        if index >= urls.count { index = max(urls.count - 1, 0) }
    }
}
