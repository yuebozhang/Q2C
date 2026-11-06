import Foundation

/// Separate configured text from the opaque clipboard payload. No clipboard read/write API here.
enum PasteSequence {
    enum Action: Equatable { case text(String), clipboard }

    static func run(header: String, footer: String,
                    validate: () throws -> Void, perform: (Action) throws -> Void) throws {
        var actions = [Action]()
        if !header.isEmpty { actions.append(.text(header + "\n")) }
        actions.append(.clipboard)
        if !footer.isEmpty { actions.append(.text("\n" + footer)) }
        for action in actions {
            try validate()
            try perform(action)
        }
    }

    /// Async delivery lets the destination process text and paste events between steps.
    @MainActor
    static func runAsync(header: String, footer: String,
                         validate: () throws -> Void,
                         perform: (Action) async throws -> Void) async throws {
        var actions = [Action]()
        if !header.isEmpty { actions.append(.text(header + "\n")) }
        actions.append(.clipboard)
        if !footer.isEmpty { actions.append(.text("\n" + footer)) }
        for action in actions {
            try validate()
            try await perform(action)
        }
    }

    static func unicodeChunks(_ text: String) -> [[UInt16]] {
        var result = [[UInt16]](), current = [UInt16]()
        for scalar in text.unicodeScalars {
            let units = Array(String(scalar).utf16)
            if current.count + units.count > 20 { result.append(current); current = [] }
            current.append(contentsOf: units)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
