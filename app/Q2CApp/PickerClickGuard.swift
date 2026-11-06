import AppKit

/// One outside press cancels selection. Its release/drag must not leak after the panel closes.
struct PickerClickPolicy {
    var selecting = true
    private(set) var swallowedButton: Int64?
    mutating func filter(button: Int64, down: Bool, up: Bool, outside: Bool) -> (swallow: Bool, cancel: Bool) {
        if swallowedButton == button {
            if up { swallowedButton = nil }
            return (true, false)
        }
        if selecting, swallowedButton == nil, down, outside {
            selecting = false
            swallowedButton = button
            return (true, true)
        }
        return (false, false)
    }
}

@MainActor
final class PickerClickGuard {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var drainTask: Task<Void, Never>?
    private var policy = PickerClickPolicy()
    private let contains: (NSPoint) -> Bool
    private let cancel: () -> Void
    private let unavailable: () -> Void

    init(contains: @escaping (NSPoint) -> Bool, cancel: @escaping () -> Void,
         unavailable: @escaping () -> Void) {
        self.contains = contains
        self.cancel = cancel
        self.unavailable = unavailable
    }

    func start() -> Bool {
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                   .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                                   .otherMouseDown, .otherMouseUp, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let swallow = MainActor.assumeIsolated {
                let owner = Unmanaged<PickerClickGuard>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    owner.unavailable()
                    owner.cancel()
                    return false
                }
                let point = NSPoint(x: event.location.x,
                                    y: (NSScreen.screens.first?.frame.maxY ?? 0) - event.location.y)
                let down = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type)
                let up = [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(type)
                let result = owner.policy.filter(button: event.getIntegerValueField(.mouseEventButtonNumber),
                                                 down: down, up: up, outside: !owner.contains(point))
                if result.cancel { owner.cancel() }
                return result.swallow
            }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stopAfterRelease() {
        policy.selecting = false
        guard policy.swallowedButton != nil else { dispose(); return }
        guard drainTask == nil else { return }
        // Retain the tap owner while draining. Never leave an indefinite global filter behind.
        drainTask = Task { @MainActor [self] in
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while policy.swallowedButton != nil, ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            dispose()
        }
    }

    private func dispose() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        drainTask = nil
    }
}
