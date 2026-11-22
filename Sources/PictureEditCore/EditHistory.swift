import Foundation

/// Every state the editable version went through, named, so the editor can undo, redo and jump
/// back to any step from its History list. Kept with the edits, so undo still works the next day.
public struct EditHistory: Codable, Equatable, Sendable {
    public struct Step: Codable, Equatable, Sendable {
        public var name: String
        public var document: EditDocument

        public init(name: String, document: EditDocument) {
            self.name = name
            self.document = document
        }
    }

    public private(set) var steps: [Step]
    public private(set) var index: Int
    /// The oldest steps go once there are more than this; the first one ("Original") always stays.
    public var limit: Int

    public init(_ document: EditDocument, limit: Int = 100) {
        steps = [Step(name: "Original", document: document)]
        index = 0
        self.limit = max(2, limit)
    }

    public var current: EditDocument { steps[index].document }
    public var canUndo: Bool { index > 0 }
    public var canRedo: Bool { index < steps.count - 1 }
    /// What Undo would undo, for the Edit menu ("Undo Arrow").
    public var undoName: String? { canUndo ? steps[index].name : nil }
    public var redoName: String? { canRedo ? steps[index + 1].name : nil }

    /// Adds a step after the current one, dropping the steps that were undone. Nothing is added when
    /// the document didn't change.
    @discardableResult
    public mutating func record(_ document: EditDocument, name: String) -> Bool {
        guard document != current else { return false }
        steps.removeSubrange((index + 1)...)
        steps.append(Step(name: name, document: document))
        index = steps.count - 1
        while steps.count > limit {
            steps.remove(at: 1)
            index -= 1
        }
        return true
    }

    @discardableResult
    public mutating func undo() -> EditDocument? {
        guard canUndo else { return nil }
        index -= 1
        return current
    }

    @discardableResult
    public mutating func redo() -> EditDocument? {
        guard canRedo else { return nil }
        index += 1
        return current
    }

    /// Goes back or forward to any step; the later steps stay until something new is done.
    @discardableResult
    public mutating func jump(to step: Int) -> EditDocument? {
        guard steps.indices.contains(step) else { return nil }
        index = step
        return current
    }

    private enum CodingKeys: String, CodingKey { case steps, index, limit }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        steps = try c.decode([Step].self, forKey: .steps)
        guard !steps.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .steps, in: c, debugDescription: "No steps")
        }
        index = min(max(try c.decodeIfPresent(Int.self, forKey: .index) ?? steps.count - 1, 0), steps.count - 1)
        limit = max(2, try c.decodeIfPresent(Int.self, forKey: .limit) ?? 100)
    }
}
