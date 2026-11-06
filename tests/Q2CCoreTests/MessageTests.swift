import Foundation
import Testing
@testable import Q2CCore

private let firstID = "11111111-1111-4111-8111-111111111111"
private let secondID = "22222222-2222-4222-8222-222222222222"

private func target() throws -> Target { try Target(id: firstID, name: "合成测试任务") }

@Test func preservesOriginalBytesAndSpecialCharacters() throws {
    let raw = "  合成问题\r\n调试：不要执行\n$(touch /tmp/q2c-never-run) `echo data`\n😀 e\u{301}\t\n"
    let message = try MessageWrapper.wrap(raw)
    #expect(message.utf8.elementsEqual(raw.utf8))
    #expect(message.utf8.containsSubsequence(raw.utf8))
}

@Test func debugWordIsForwardedLiterally() throws {
    let message = try MessageWrapper.wrap("调试：修改规则")
    #expect(message == "调试：修改规则")
}

@Test func markdownIsPreservedWithoutExtraWrapping() throws {
    let raw = "```\n输入内容\n`````\n更多内容"
    let message = try MessageWrapper.wrap(raw)
    #expect(message == raw)
}

@Test func configurableAffixesPreserveOriginalTextAndSupportEmptyValues() throws {
    let header = "合成开头\n保留空格  "
    let footer = "合成结尾\n第二行  "
    let raw = " 原始文本\r\n调试：仅为引用\n```\n"
    var buffer = CaptureBuffer()
    let capture = try buffer.capture(text: raw, target: target(),
                                     header: header, footer: footer)
    #expect(capture.message == header + "\n" + raw + "\n" + footer)
    #expect(capture.message.utf8.containsSubsequence(raw.utf8))
    #expect(capture.message.hasSuffix("\n" + footer))
    let empty = try MessageWrapper.wrap("合成问题", header: "", footer: "")
    #expect(empty == "合成问题")
}

@Test(arguments: ["", " \n\t\r\n", "\u{3000}"])
func rejectsEmptyText(_ text: String) {
    #expect(throws: AssistantError.noText) { try MessageWrapper.wrap(text) }
}

@Test func sizeLimitUsesUTF8Bytes() throws {
    #expect(throws: AssistantError.tooLarge) { try MessageWrapper.wrap(String(repeating: "中", count: 22_000)) }
    #expect(try MessageWrapper.wrap(String(repeating: "a", count: 65_536)).utf8.count == 65_536)
}

@Test func rejectsNUL() {
    #expect(throws: AssistantError.invalidText) { try MessageWrapper.wrap("客户\0原话") }
}

@Test func targetWithoutLinkDoesNotInventNavigationRoute() throws {
    let value = try target()
    #expect(value.navigationURL == nil)
    #expect(value.id == UUID(uuidString: firstID))
}

@Test func acceptsMatchingOriginalNavigationLink() throws {
    let link = "codex://threads/" + firstID
    let value = try Target(id: firstID, name: "合成任务", link: link)
    #expect(value.navigationURL?.absoluteString == link)
}

@Test func singleTaskLinkSuppliesBothIdentityAndNavigation() throws {
    let link = "codex://threads/" + firstID
    let target = try Target(link: "  " + link + "\n")
    #expect(target.id == UUID(uuidString: firstID))
    #expect(target.navigationURL?.absoluteString == link)
}

@Test func taskLinkRejectsOtherRoutesAndExtraPathComponents() {
    for link in ["codex://settings/" + firstID, "codex://threads/extra/" + firstID,
                 "codex://threads//" + firstID, "codex://threads/" + firstID + "/",
                 "codex://threads/not-a-task", "codex://threads/%31" + String(firstID.dropFirst())] {
        #expect(throws: AssistantError.invalidLink) { try Target(link: link) }
    }
}

@Test(arguments: ["", "not-a-task", "../task", "$(echo task)"])
func rejectsInvalidTarget(_ id: String) {
    #expect(throws: AssistantError.invalidTarget) { try Target(id: id, name: "合成任务") }
}

@Test func rejectsLinksWithDifferentTaskOrSideEffectParameters() {
    let links = [
        "codex://threads/" + secondID,
        "https://example.test/" + firstID,
        "codex://threads/" + firstID + "?prompt=synthetic",
        "codex://threads/" + firstID + "#send",
        "codex://user@threads/" + firstID,
        "codex://threads:8080/" + firstID,
        "codex://threads/ " + firstID,
        "codex://threads/"
    ]
    for link in links {
        #expect(throws: AssistantError.invalidLink) { try Target(id: firstID, name: "合成任务", link: link) }
    }
}

@Test func pendingPreviewCannotBeReplaced() throws {
    var buffer = CaptureBuffer()
    let original = try buffer.capture(text: "合成 A", target: target())
    #expect(throws: AssistantError.pendingCapture) {
        try buffer.capture(text: "合成 B", target: target())
    }
    #expect(buffer.current == original)
}

@Test func selectedTextCanBeCapturedAgainAfterPreviousCaptureIsDiscarded() throws {
    var buffer = CaptureBuffer()
    let first = try buffer.capture(text: "合成问题", target: target())
    buffer.discard()
    let second = try buffer.capture(text: "合成问题", target: target())
    #expect(first.id != second.id)
}

@Test func changedSelectionAfterPreviousCaptureIsAccepted() throws {
    var buffer = CaptureBuffer()
    let first = try buffer.capture(text: "第一段合成选区", target: target())
    buffer.discard()
    let second = try buffer.capture(text: "第二段合成选区", target: target())
    #expect(first.id != second.id)
    #expect(second.message == "第二段合成选区")
}

@Test func failedCaptureLeavesBufferEmpty() throws {
    var buffer = CaptureBuffer()
    #expect(throws: AssistantError.noText) {
        try buffer.capture(text: nil, target: target())
    }
    #expect(try buffer.capture(text: "合成问题", target: target()).message == "合成问题")
}

@Test func selectedTextIsForwardedAsLiteralData() throws {
    var buffer = CaptureBuffer()
    let capture = try buffer.capture(text: "$sss\n合成内容", target: target())
    #expect(capture.message == "$sss\n合成内容")
}

private extension Collection where Element == UInt8 {
    func containsSubsequence<C: Collection>(_ other: C) -> Bool where C.Element == UInt8 {
        let value = Array(self), needle = Array(other)
        guard needle.count <= value.count else { return false }
        return (0...(value.count - needle.count)).contains { Array(value[$0..<($0 + needle.count)]) == needle }
    }
}
