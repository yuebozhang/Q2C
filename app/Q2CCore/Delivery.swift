import Foundation

/// Strict identity remains the default. Configured navigation is an explicit
/// desktop mode for apps whose AX document does not expose a thread identifier.
public enum DesktopRoutingPolicy: Sendable {
    case verifiedIdentity
    case configuredNavigation
}

public enum DeliveryState: Equatable, Sendable {
    case prepared, staged, submitting, uncertain, submitted, running, completed, failed
}

public struct DesktopSnapshot: Equatable, Sendable {
    public let targetID: UUID?
    public let revision: String
    public let draft: String?
    public let hasAttachments: Bool?
    public let busy: Bool?

    public init(targetID: UUID?, revision: String, draft: String?, hasAttachments: Bool?, busy: Bool?) {
        self.targetID = targetID
        self.revision = revision
        self.draft = draft
        self.hasAttachments = hasAttachments
        self.busy = busy
    }
}

/// A desktop adapter MUST recheck the snapshot at the actual write/press
/// boundary. Returning from submit means accepted by the transport, NOT acknowledged.
/// AX input clearing, a click succeeding, and elapsed time are not acknowledgements.
@MainActor
public protocol DesktopTransport: AnyObject {
    var isVerified: Bool { get }
    func inspect(target: Target) throws -> DesktopSnapshot
    func fill(message: String, target: Target, expected: DesktopSnapshot) throws
    func submit(message: String, target: Target, expected: DesktopSnapshot) throws
}

/// Fallback transport for installations without a supported desktop adapter.
@MainActor
public final class UnavailableDesktopTransport: DesktopTransport {
    public init() {}
    public var isVerified: Bool { false }
    public func inspect(target: Target) throws -> DesktopSnapshot { throw AssistantError.adapterUnavailable }
    public func fill(message: String, target: Target, expected: DesktopSnapshot) throws { throw AssistantError.adapterUnavailable }
    public func submit(message: String, target: Target, expected: DesktopSnapshot) throws { throw AssistantError.adapterUnavailable }
}

/// Guarded delivery lifecycle shared by desktop adapters.
@MainActor
public final class DeliverySession {
    public let capture: Capture
    public private(set) var state: DeliveryState = .prepared
    private let transport: any DesktopTransport
    private let routingPolicy: DesktopRoutingPolicy

    public init(capture: Capture, transport: any DesktopTransport,
                routingPolicy: DesktopRoutingPolicy = .verifiedIdentity) {
        self.capture = capture
        self.transport = transport
        self.routingPolicy = routingPolicy
    }

    private func snapshot(expectedDraft: String) throws -> DesktopSnapshot {
        guard transport.isVerified else { throw AssistantError.adapterUnavailable }
        let value = try transport.inspect(target: capture.target)
        switch routingPolicy {
        case .verifiedIdentity:
            guard value.targetID == capture.target.id else { throw AssistantError.unverifiedTarget }
        case .configuredNavigation:
            // Missing AX identity is allowed by this explicit policy. Contrary
            // identity evidence always stops delivery, even in navigation mode.
            guard value.targetID == nil || value.targetID == capture.target.id else {
                throw AssistantError.unverifiedTarget
            }
        }
        guard let draft = value.draft, let attachments = value.hasAttachments, let busy = value.busy else {
            throw AssistantError.unreadableDraft
        }
        guard !busy else { throw AssistantError.busy }
        guard !attachments else { throw AssistantError.existingDraft }
        guard draft.utf8.elementsEqual(expectedDraft.utf8) else {
            throw expectedDraft.isEmpty ? AssistantError.existingDraft : AssistantError.changedState
        }
        guard !value.revision.isEmpty else { throw AssistantError.changedState }
        return value
    }

    public func stage() throws {
        guard state == .prepared else { throw AssistantError.invalidTransition }
        let before = try snapshot(expectedDraft: "")
        // A failed/partially applied fill must never be replayed automatically.
        state = .failed
        try transport.fill(message: capture.message, target: capture.target, expected: before)
        _ = try snapshot(expectedDraft: capture.message)
        state = .staged
    }

    public func submit() throws {
        guard state != .uncertain else { throw AssistantError.uncertainSubmission }
        guard state == .staged else { throw AssistantError.invalidTransition }
        let before = try snapshot(expectedDraft: capture.message)
        // Mark before the side effect. Even an exception may follow a successful press.
        state = .submitting
        do {
            try transport.submit(message: capture.message, target: capture.target, expected: before)
        } catch {
            state = .uncertain
            throw AssistantError.uncertainSubmission
        }
    }

    public func submissionTimedOut() throws {
        guard state == .submitting else { throw AssistantError.invalidTransition }
        state = .uncertain
    }

    /// Called ONLY with a transport acknowledgement uniquely correlated to this event.
    public func acknowledge(captureID: UUID, targetID: UUID) throws {
        guard captureID == capture.id, targetID == capture.target.id,
              state == .submitting || state == .uncertain else { throw AssistantError.invalidTransition }
        state = .submitted
    }

    public func markRunning() throws {
        guard state == .submitted else { throw AssistantError.invalidTransition }
        state = .running
    }

    public func finish(success: Bool) throws {
        guard state == .submitted || state == .running else { throw AssistantError.invalidTransition }
        state = success ? .completed : .failed
    }
}
