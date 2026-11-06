import ApplicationServices
import Testing
@testable import Q2CApp

@Test func unsupportedChildrenOnKnownLeafDoNotInvalidateTheWholeScan() {
    for role in [kAXButtonRole, kAXStaticTextRole, kAXImageRole, kAXTextAreaRole] {
        for error in [AXError.attributeUnsupported, .noValue] {
            #expect(InputDiscoveryPolicy.canTreatAsLeaf(role: role, error: error.rawValue))
        }
    }
}

@Test func unreadableContainersCannotConcealAnotherInput() {
    for role in [kAXWindowRole, kAXGroupRole, kAXScrollAreaRole, "AXWebArea", "AXUnknown"] {
        for error in [AXError.attributeUnsupported, .noValue, .cannotComplete, .invalidUIElement, .success] {
            #expect(!InputDiscoveryPolicy.canTreatAsLeaf(role: role, error: error.rawValue))
        }
    }
}

@Test func actualAXFailuresNeverBecomeSafeLeafEvidence() {
    for role in [kAXButtonRole, kAXStaticTextRole, kAXTextAreaRole] {
        for error in [AXError.cannotComplete, .invalidUIElement, .apiDisabled, .failure, .success] {
            #expect(!InputDiscoveryPolicy.canTreatAsLeaf(role: role, error: error.rawValue))
        }
    }
}
