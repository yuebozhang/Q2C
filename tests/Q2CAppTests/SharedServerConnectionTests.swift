import Foundation
import Testing
@testable import Q2CApp

@Test func sharedConnectionUsesExplicitSocketOrCodexHome() {
    let home = URL(fileURLWithPath: "/synthetic/home")
    #expect(SharedServerConnection.socketURL(environment: [:], home: home).path == "/synthetic/home/.codex/app-server-control/app-server-control.sock")
    #expect(SharedServerConnection.socketURL(environment: ["CODEX_HOME": "/synthetic/codex"], home: home).path == "/synthetic/codex/app-server-control/app-server-control.sock")
    #expect(SharedServerConnection.socketURL(environment: ["Q2C_APP_SERVER_SOCKET": "/synthetic/shared.sock", "CODEX_HOME": "/synthetic/codex"], home: home).path == "/synthetic/shared.sock")
}

@Test func sharedConnectionRejectsMissingSocketAndRegularFiles() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    #expect(!SharedServerConnection.isSocket(file))
    try Data("synthetic".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(!SharedServerConnection.isSocket(file))
}
