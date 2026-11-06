import AppKit
import Darwin
import Foundation
import Q2CCore

@MainActor
final class CodexAppServerSender {
    enum Event: Sendable {
        case submitted
        case approvalRequired
        case completed
        case failed(String)
        case uncertain(String)
    }

    func submit(target: Target, message: String, traceID: String, onEvent: @escaping @MainActor @Sendable (Event) -> Void) {
        let targetID = target.id.uuidString.lowercased()
        let executablePath = Self.codexExecutable()?.path
        DiagnosticLog.shared.record("submit.requested", trace: traceID, fields: ["cliFound": String(executablePath != nil)])
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try Self.run(targetID: targetID, message: message, executablePath: executablePath, traceID: traceID) { event in
                    Task { @MainActor in onEvent(event) }
                }
            } catch let error as SenderError {
                DiagnosticLog.shared.record("submit.failed", trace: traceID, fields: ["reason": error.logCode])
                Task { @MainActor in
                    if error.isUncertain { onEvent(.uncertain(error.localizedDescription)) }
                    else { onEvent(.failed(error.localizedDescription)) }
                }
            } catch {
                DiagnosticLog.shared.record("submit.unknownError", trace: traceID, fields: ["errorType": String(reflecting: type(of: error))])
                Task { @MainActor in onEvent(.uncertain("提交状态无法确认，请检查目标任务后再处理。")) }
            }
        }
    }

    private enum SenderError: Error, LocalizedError {
        case missingCLI, sharedServerUnavailable, launchFailed, timeout, serverClosed, invalidResponse
        case rpcRejected(String), threadMismatch, threadBusy, unreadableStatus
        case turnFailed(String), uncertain

        var logCode: String {
            switch self {
            case .missingCLI: "missingCLI"
            case .sharedServerUnavailable: "sharedServerUnavailable"
            case .launchFailed: "launchFailed"
            case .timeout: "timeout"
            case .serverClosed: "serverClosed"
            case .invalidResponse: "invalidResponse"
            case .rpcRejected: "rpcRejected"
            case .threadMismatch: "threadMismatch"
            case .threadBusy: "threadBusy"
            case .unreadableStatus: "unreadableStatus"
            case .turnFailed: "turnFailed"
            case .uncertain: "uncertain"
            }
        }

        var isUncertain: Bool {
            switch self {
            case .uncertain: true
            default: false
            }
        }

        var errorDescription: String? {
            switch self {
            case .missingCLI: "找不到 Codex CLI，无法启动后台提交。"
            case .sharedServerUnavailable: "当前 Codex 未提供共享连接，无法后台转发（共享 socket 不存在）。"
            case .launchFailed: "无法连接 Codex 共享 App Server。"
            case .timeout: "Codex App Server 响应超时。"
            case .serverClosed: "Codex App Server 提前关闭。"
            case .invalidResponse: "Codex App Server 返回了无法识别的响应。"
            case .rpcRejected(let message): "Codex 拒绝了这次提交：\(message)"
            case .threadMismatch: "链接对应的任务与 Codex 返回的任务 ID 不一致，已停止。"
            case .threadBusy: "目标任务正在处理其他消息，已停止。"
            case .unreadableStatus: "无法确认目标任务的运行状态，已停止。"
            case .turnFailed(let status): "消息已提交，但 Codex 处理状态为 \(status)。请检查目标任务。"
            case .uncertain: "提交结果不确定，请检查目标任务；Q2C 不会自动重试。"
            }
        }
    }

    private nonisolated static func run(targetID: String, message: String, executablePath: String?, traceID: String,
                                       onEvent: @Sendable (Event) -> Void) throws {
        guard let executablePath else { throw SenderError.missingCLI }

        let socketURL = SharedServerConnection.socketURL()
        guard SharedServerConnection.isSocket(socketURL) else {
            DiagnosticLog.shared.record("proxy.unavailable", trace: traceID)
            throw SenderError.sharedServerUnavailable
        }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["app-server", "proxy", "--sock", socketURL.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { throw SenderError.launchFailed }
        DiagnosticLog.shared.record("proxy.started", trace: traceID, fields: ["childPID": String(process.processIdentifier)])
        defer {
            DiagnosticLog.shared.record("proxy.closing", trace: traceID, fields: ["running": String(process.isRunning)])
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            output.fileHandleForReading.closeFile()
        }

        let reader = JSONLineReader(fileHandle: output.fileHandleForReading)
        var pendingNotifications = [[String: Any]]()
        try write(["id": 1, "method": "initialize", "params": [
            "clientInfo": ["name": "q2c", "title": "Q2C", "version": "0.2.0"]
        ]], to: input)
        _ = try response(id: 1, reader: reader, timeout: 15, pendingNotifications: &pendingNotifications)
        try write(["method": "initialized", "params": [:]], to: input)

        try write(["id": 2, "method": "thread/read", "params": ["threadId": targetID]], to: input)
        let initial = try response(id: 2, reader: reader, timeout: 20, pendingNotifications: &pendingNotifications)
        try verifyThread(initial, expectedID: targetID)
        try verifyIdleStatus(initial)

        try write(["id": 3, "method": "thread/resume", "params": [
            "threadId": targetID, "excludeTurns": true
        ]], to: input)
        let resumed = try response(id: 3, reader: reader, timeout: 20, pendingNotifications: &pendingNotifications)
        try verifyThread(resumed, expectedID: targetID)

        // Recheck immediately before sending to catch a turn that started during resume.
        try write(["id": 4, "method": "thread/read", "params": ["threadId": targetID]], to: input)
        let latest = try response(id: 4, reader: reader, timeout: 20, pendingNotifications: &pendingNotifications)
        try verifyThread(latest, expectedID: targetID)
        try verifyIdleStatus(latest)

        do {
            try write(["id": 5, "method": "turn/start", "params": [
                "threadId": targetID,
                "input": [["type": "text", "text": message]]
            ]], to: input)
        } catch {
            throw SenderError.uncertain
        }

        let start: [String: Any]
        do {
            start = try response(id: 5, reader: reader, timeout: 30,
                                 pendingNotifications: &pendingNotifications)
        }
        catch SenderError.rpcRejected(let message) { throw SenderError.rpcRejected(message) }
        catch { throw SenderError.uncertain }

        guard let result = start["result"] as? [String: Any],
              let turn = result["turn"] as? [String: Any],
              let turnID = turn["id"] as? String, !turnID.isEmpty else {
            throw SenderError.uncertain
        }
        DiagnosticLog.shared.record("turn.accepted", trace: traceID)
        onEvent(.submitted)

        for notification in pendingNotifications {
            if try consumeNotification(notification, turnID: turnID, input: input, onEvent: onEvent) {
                return
            }
        }

        let deadline = Date().addingTimeInterval(30 * 60)
        while Date() < deadline {
            let event = try reader.readLine(timeout: min(30, deadline.timeIntervalSinceNow))
            guard let object = try JSONSerialization.jsonObject(with: event) as? [String: Any] else {
                throw SenderError.uncertain
            }
            if try consumeNotification(object, turnID: turnID, input: input, onEvent: onEvent) { return }
        }
        throw SenderError.uncertain
    }

    private nonisolated static func consumeNotification(_ notification: [String: Any], turnID: String,
                                                        input: Pipe, onEvent: @Sendable (Event) -> Void) throws -> Bool {
        let method = notification["method"] as? String
        if method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval" {
            try declineApproval(notification, to: input)
            onEvent(.approvalRequired)
            return false
        }
        guard method == "turn/completed",
              let params = notification["params"] as? [String: Any],
              let completedTurn = params["turn"] as? [String: Any],
              completedTurn["id"] as? String == turnID else {
            return false
        }

        let status = completedTurn["status"] as? String
        DiagnosticLog.shared.record("turn.finished", fields: ["status": ["completed", "failed", "interrupted"].contains(status ?? "") ? status! : "unknown"])
        if status == "completed" {
            onEvent(.completed)
            return true
        }
        throw SenderError.turnFailed(status ?? "未知")
    }

    private nonisolated static func verifyThread(_ response: [String: Any], expectedID: String) throws {
        guard let result = response["result"] as? [String: Any],
              let thread = result["thread"] as? [String: Any],
              let id = thread["id"] as? String,
              UUID(uuidString: id)?.uuidString.lowercased() == expectedID else {
            throw SenderError.threadMismatch
        }
    }

    private nonisolated static func verifyIdleStatus(_ response: [String: Any]) throws {
        guard let result = response["result"] as? [String: Any],
              let thread = result["thread"] as? [String: Any],
              let status = thread["status"] as? [String: Any],
              let type = status["type"] as? String else {
            throw SenderError.unreadableStatus
        }
        DiagnosticLog.shared.record("thread.status", fields: ["status": ["idle", "notLoaded", "active", "systemError"].contains(type) ? type : "unknown"])
        guard type == "idle" || type == "notLoaded" else { throw SenderError.threadBusy }
    }

    private nonisolated static func response(id: Int, reader: JSONLineReader,
                                             timeout: TimeInterval,
                                             pendingNotifications: inout [[String: Any]]) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let line = try reader.readLine(timeout: deadline.timeIntervalSinceNow)
            guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw SenderError.invalidResponse
            }
            if (object["id"] as? NSNumber)?.intValue == id {
                DiagnosticLog.shared.record("rpc.response", fields: ["id": String(id), "success": String(object["error"] == nil)])
                if let error = object["error"] as? [String: Any] {
                    DiagnosticLog.shared.record("rpc.rejected", fields: ["id": String(id), "code": (error["code"] as? NSNumber)?.stringValue ?? "unknown"])
                    throw SenderError.rpcRejected(error["message"] as? String ?? "未知错误")
                }
                return object
            }
            if object["method"] is String { pendingNotifications.append(object) }
        }
        throw SenderError.timeout
    }

    private nonisolated static func declineApproval(_ request: [String: Any], to input: Pipe) throws {
        guard let id = request["id"] else { return }
        try write(["id": id, "result": ["decision": "decline"]], to: input)
    }

    private nonisolated static func write(_ object: [String: Any], to input: Pipe) throws {
        if let method = object["method"] as? String,
           ["initialize", "initialized", "thread/read", "thread/resume", "turn/start"].contains(method) {
            DiagnosticLog.shared.record("rpc.sending", fields: ["method": method, "id": (object["id"] as? NSNumber)?.stringValue ?? "notification"])
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
        var line = data
        line.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: line)
    }

    private static func codexExecutable() -> URL? {
        var candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("codex") }
        if let codexApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            candidates.append(codexApp.appendingPathComponent(
                "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"))
        }
        candidates += [URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
                       URL(fileURLWithPath: "/usr/local/bin/codex")]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

private final class JSONLineReader {
    private let fileHandle: FileHandle
    private var buffer = Data()

    init(fileHandle: FileHandle) { self.fileHandle = fileHandle }

    func readLine(timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        let newline = Data([0x0A])
        while Date() < deadline {
            if let range = buffer.range(of: newline) {
                let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return line
            }

            var descriptor = pollfd(fd: fileHandle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let remainingMilliseconds = Int32(max(1, min(30_000, Int(deadline.timeIntervalSinceNow * 1000))))
            let ready = Darwin.poll(&descriptor, nfds_t(1), remainingMilliseconds)
            if ready == 0 { throw SenderReadError.timeout }
            if ready < 0 {
                if errno == EINTR { continue }
                throw SenderReadError.closed
            }

            var bytes = [UInt8](repeating: 0, count: 16 * 1024)
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fileHandle.fileDescriptor, $0.baseAddress, $0.count) }
            guard count > 0 else { throw SenderReadError.closed }
            buffer.append(contentsOf: bytes.prefix(count))
        }
        throw SenderReadError.timeout
    }
}

private enum SenderReadError: Error {
    case timeout, closed
}
