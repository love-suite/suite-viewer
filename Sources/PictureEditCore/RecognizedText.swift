import CoreGraphics
import Foundation
import Vision

/// The text found in a picture, word by word, with where each word sits, so it can be selected by
/// dragging across it, copied and searched, as Live Text in Preview and "Scan text" in Windows' Photos.
/// Boxes are fractions of the picture (0 to 1), origin at the top left.
public struct RecognizedText: Equatable, Sendable {
    public struct Word: Equatable, Sendable {
        public var text: String
        public var box: CGRect
        public var line: Int

        public init(text: String, box: CGRect, line: Int) {
            self.text = text; self.box = box; self.line = line
        }
    }

    /// In reading order.
    public private(set) var words: [Word]

    public init(words: [Word]) {
        self.words = words
    }

    /// Lines of words, each word with its box.
    public init(lines: [[(String, CGRect)]]) {
        words = lines.enumerated().flatMap { index, line in line.map { Word(text: $0.0, box: $0.1, line: index) } }
    }

    public static let empty = RecognizedText(words: [])
    public var isEmpty: Bool { words.isEmpty }

    /// All the text, lines separated by line breaks.
    public var fullText: String { words.isEmpty ? "" : text(in: 0...(words.count - 1)) }

    /// The words from one to another, inclusive, joined as they read.
    public func text(in range: ClosedRange<Int>) -> String {
        let range = range.clamped(to: 0...max(0, words.count - 1))
        guard !words.isEmpty else { return "" }
        var result = ""
        var previous: Word?
        for word in words[range] {
            if let previous { result += previous.line == word.line ? " " : "\n" }
            result += word.text
            previous = word
        }
        return result
    }

    /// The word under `point`, with `tolerance` (a fraction of the picture) around each box.
    public func word(at point: CGPoint, tolerance: Double = 0) -> Int? {
        words.firstIndex { $0.box.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }
    }

    /// The word closest to `point`, for the end of a selection dragged past the text.
    public func nearestWord(to point: CGPoint) -> Int? {
        guard !words.isEmpty else { return nil }
        func distance(_ box: CGRect) -> Double {
            let dx = max(box.minX - point.x, 0, point.x - box.maxX)
            // Rows count more than columns, so a drag along a line stays on it.
            let dy = max(box.minY - point.y, 0, point.y - box.maxY) * 3
            return dx * dx + dy * dy
        }
        return words.indices.min { distance(words[$0].box) < distance(words[$1].box) }
    }

    /// The boxes covering a run of words, one per line.
    public func boxes(for range: ClosedRange<Int>) -> [CGRect] {
        guard !words.isEmpty else { return [] }
        let range = range.clamped(to: 0...(words.count - 1))
        var boxes: [CGRect] = []
        var line = -1
        for word in words[range] {
            if word.line == line, let last = boxes.last {
                boxes[boxes.count - 1] = last.union(word.box)
            } else {
                boxes.append(word.box)
                line = word.line
            }
        }
        return boxes
    }

    /// The runs of words matching `query`, ignoring case and accents.
    public func matches(of query: String) -> [ClosedRange<Int>] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, !words.isEmpty else { return [] }
        // The text with every character mapped to its word, line breaks counted as spaces.
        var haystack = ""
        var owners: [Int] = []
        for (index, word) in words.enumerated() {
            if index > 0 { haystack += " "; owners.append(index) }
            haystack += word.text
            owners += Array(repeating: index, count: word.text.count)
        }
        var result: [ClosedRange<Int>] = []
        var searchStart = haystack.startIndex
        while let found = haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive],
                                         range: searchStart..<haystack.endIndex) {
            let lower = haystack.distance(from: haystack.startIndex, to: found.lowerBound)
            let upper = haystack.distance(from: haystack.startIndex, to: found.upperBound) - 1
            result.append(owners[lower]...owners[max(lower, upper)])
            searchStart = found.upperBound
        }
        return result
    }
}

/// Reads the text in a picture on this Mac with Vision: nothing leaves it.
public enum TextRecognition {
    public static func recognize(_ image: CGImage) -> RecognizedText {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if #available(macOS 13, *) { request.automaticallyDetectsLanguage = true }
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            return .empty
        }
        let lines: [[(String, CGRect)]] = (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let string = candidate.string
            var words: [(String, CGRect)] = []
            var index = string.startIndex
            while index < string.endIndex {
                guard let start = string[index...].firstIndex(where: { !$0.isWhitespace }) else { break }
                let end = string[start...].firstIndex(where: \.isWhitespace) ?? string.endIndex
                let box = (try? candidate.boundingBox(for: start..<end))?.boundingBox ?? observation.boundingBox
                words.append((String(string[start..<end]), flipped(box)))
                index = end
            }
            return words.isEmpty ? nil : words
        }
        return RecognizedText(lines: lines)
    }

    /// Vision's boxes have their origin at the bottom left.
    static func flipped(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }
}
