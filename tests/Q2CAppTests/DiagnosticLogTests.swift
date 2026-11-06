import Foundation
import Testing
@testable import Q2CApp

@Test func diagnosticLogSerializesConcurrentEventsAndRestrictsPermissions() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let logger = DiagnosticLog(directory: directory)
    DispatchQueue.concurrentPerform(iterations: 40) { index in
        logger.record("synthetic.event", trace: "synthetic", fields: ["index": String(index)])
    }
    let lines = try String(contentsOf: logger.fileURL, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 40)
    for line in lines {
        let record = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String]
        #expect(record?["event"] == "synthetic.event")
        #expect(record?["trace"] == "synthetic")
        #expect(record?["time"] != nil)
    }
    let permissions = try FileManager.default.attributesOfItem(atPath: logger.fileURL.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
}

@Test func diagnosticLogRotatesAtSizeLimit() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let logger = DiagnosticLog(directory: directory)
    logger.record("synthetic.first")
    try Data(repeating: 0x20, count: 1_048_576).write(to: logger.fileURL)
    logger.record("synthetic.afterRotation")
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("diagnostic.previous.jsonl").path))
    let contents = try String(contentsOf: logger.fileURL, encoding: .utf8)
    #expect(contents.contains("synthetic.afterRotation"))
    #expect(contents.utf8.count < 1024)
}
