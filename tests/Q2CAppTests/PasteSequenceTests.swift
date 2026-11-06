import Testing
@testable import Q2CApp

@Test func noAffixesRequestOnlyOneUnmodifiedClipboardPaste() throws {
    var actions = [PasteSequence.Action]()
    try PasteSequence.run(header: "", footer: "", validate: {}, perform: { actions.append($0) })
    #expect(actions == [.clipboard])
}

@Test func affixesAreSeparateUnicodeTextAroundOneClipboardPaste() throws {
    var actions = [PasteSequence.Action]()
    try PasteSequence.run(header: "开头😀", footer: "结尾", validate: {}, perform: { actions.append($0) })
    #expect(actions == [.text("开头😀\n"), .clipboard, .text("\n结尾")])
}

@Test func clipboardOrFocusChangeAfterHeaderStopsPasteAndFooter() {
    enum Changed: Error { case clipboard }
    var actions = [PasteSequence.Action](), checks = 0
    #expect(throws: Changed.self) {
        try PasteSequence.run(header: "头", footer: "尾", validate: {
            checks += 1
            if checks == 2 { throw Changed.clipboard }
        }, perform: { actions.append($0) })
    }
    #expect(actions == [.text("头\n")])
}

@Test func failureAfterPasteNeverRetriesOrInputsFooter() {
    enum Failed: Error { case event }
    var actions = [PasteSequence.Action]()
    #expect(throws: Failed.self) {
        try PasteSequence.run(header: "头", footer: "尾", validate: {}, perform: {
            actions.append($0)
            if $0 == .clipboard { throw Failed.event }
        })
    }
    #expect(actions == [.text("头\n"), .clipboard])
}

@Test func unicodeChunksPreserveSurrogatesNewlinesAndExactText() {
    let text = String(repeating: "中文😀e\u{301}\n", count: 15)
    let chunks = PasteSequence.unicodeChunks(text)
    #expect(chunks.allSatisfy { $0.count <= 20 && !$0.isEmpty })
    #expect(chunks.allSatisfy { String(decoding: $0, as: UTF16.self).utf16.elementsEqual($0) })
    #expect(chunks.flatMap { $0 } == Array(text.utf16))
}

@Test @MainActor func asyncAffixesAndPasteStayOrderedAcrossProcessingGaps() async throws {
    var sent: [PasteSequence.Action] = []
    try await PasteSequence.runAsync(header: "synthetic header", footer: "synthetic footer", validate: {}, perform: {
        await Task.yield()
        sent.append($0)
    })
    #expect(sent == [.text("synthetic header\n"), .clipboard, .text("\nsynthetic footer")])
}

@Test @MainActor func changedStateBetweenAsyncActionsStopsBeforePaste() async throws {
    var valid = true
    var sent: [PasteSequence.Action] = []
    do {
        try await PasteSequence.runAsync(header: "synthetic", footer: "tail", validate: {
            if !valid { throw CancellationError() }
        }, perform: {
            sent.append($0)
            await Task.yield()
            valid = false
        })
        Issue.record("Expected cancellation before clipboard action")
    } catch is CancellationError { }
    #expect(sent == [.text("synthetic\n")])
}
