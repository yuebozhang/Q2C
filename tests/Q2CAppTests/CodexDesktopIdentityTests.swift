import Foundation
import Testing
@testable import Q2CApp

@Test func desktopIdentityRequiresExactUnambiguousDocumentRoute() throws {
    let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let other = "22222222-2222-4222-8222-222222222222"
    #expect(CodexDesktopIdentity.matches(documents: ["codex://threads/\(id)"], targetID: id))
    #expect(CodexDesktopIdentity.matches(documents: ["http://localhost/local/\(id)"], targetID: id))
    #expect(!CodexDesktopIdentity.matches(documents: [], targetID: id))
    #expect(!CodexDesktopIdentity.matches(documents: ["Task title \(id)"], targetID: id))
    #expect(!CodexDesktopIdentity.matches(documents: ["codex://threads/\(other)"], targetID: id))
    #expect(!CodexDesktopIdentity.matches(documents: ["codex://threads/\(id)", "codex://threads/\(other)"], targetID: id))
    #expect(!CodexDesktopIdentity.matches(documents: ["http://localhost/local/\(id)?other=1"], targetID: id))
}
