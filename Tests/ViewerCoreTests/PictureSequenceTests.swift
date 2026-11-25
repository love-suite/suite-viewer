import Foundation
import Testing
@testable import ViewerCore

@Suite struct PictureSequenceTests {
    private func item(_ name: String, folder: Bool = false) -> FolderFile {
        FolderFile(url: URL(fileURLWithPath: "/pics/\(name)"), name: name, isDirectory: folder)
    }

    private var items: [FolderFile] {
        [item("Holidays", folder: true), item("a.jpg"), item("notes.txt"), item("b.PNG"), item("c.heic"),
         item("scan.pdf")]
    }

    @Test func keepsOnlyPicturesInTheFolderOrder() {
        let sequence = PictureSequence(items: items, current: URL(fileURLWithPath: "/pics/b.PNG"))
        #expect(sequence.urls.map(\.lastPathComponent) == ["a.jpg", "b.PNG", "c.heic"])
        #expect(sequence.index == 1)
        #expect(sequence.position == "2 of 3")
    }

    @Test func wrapsAroundBothWays() {
        var sequence = PictureSequence(items: items, current: URL(fileURLWithPath: "/pics/c.heic"))
        sequence.next()
        #expect(sequence.current?.lastPathComponent == "a.jpg")
        sequence.previous()
        #expect(sequence.current?.lastPathComponent == "c.heic")
    }

    @Test func deletingShowsTheNextOrThePrevious() {
        var sequence = PictureSequence(items: items, current: URL(fileURLWithPath: "/pics/a.jpg"))
        sequence.removeCurrent()
        #expect(sequence.current?.lastPathComponent == "b.PNG")
        sequence.next()
        sequence.removeCurrent()
        #expect(sequence.current?.lastPathComponent == "b.PNG")
        sequence.removeCurrent()
        #expect(sequence.isEmpty)
        #expect(sequence.current == nil)
    }

    @Test func aPictureOutsideTheListingStillShows() {
        let sequence = PictureSequence(items: [], current: URL(fileURLWithPath: "/elsewhere/x.gif"))
        #expect(sequence.urls.count == 1)
        #expect(sequence.position == "1 of 1")
    }

    @Test func picturesAreImagesButNotPDFs() {
        #expect(PictureSequence.isPicture(URL(fileURLWithPath: "/a.jpeg")))
        #expect(PictureSequence.isPicture(URL(fileURLWithPath: "/a.gif")))
        #expect(!PictureSequence.isPicture(URL(fileURLWithPath: "/a.pdf")))
        #expect(!PictureSequence.isPicture(URL(fileURLWithPath: "/a.txt")))
        #expect(!PictureSequence.isPicture(URL(fileURLWithPath: "/noextension")))
    }
}
