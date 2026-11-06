import Testing
@testable import Q2CApp

@Test func matchingTaskCanSkipNavigationSettling() {
    #expect(PasteReadiness.decision(elapsed: 0, evidence: .notReady) != .ready)
    #expect(PasteReadiness.decision(elapsed: 0.1, evidence: .otherTarget) != .ready)
    #expect(PasteReadiness.decision(elapsed: 0.2, evidence: .targetMatched) == .ready)
}

@Test func inputWithoutTaskIdentityStillWaitsForNavigationSettling() {
    #expect(PasteReadiness.decision(elapsed: 0.25, evidence: .unidentified) == .wait(0.25))
    #expect(PasteReadiness.decision(elapsed: 0.49, evidence: .unidentified) != .ready)
    #expect(PasteReadiness.decision(elapsed: 0.5, evidence: .unidentified) == .ready)
}

@Test func contraryTaskIdentityNeverBecomesReadyByWaiting() {
    for elapsed in [0.0, 0.5, 1, 6.99] {
        #expect(PasteReadiness.decision(elapsed: elapsed, evidence: .otherTarget) != .ready)
    }
    #expect(PasteReadiness.decision(elapsed: 7, evidence: .otherTarget) == .timedOut)
}

@Test func slowAccessibilityQueriesCannotExtendTheReadinessDeadline() {
    for evidence: PasteReadiness.Evidence in [.notReady, .targetMatched, .unidentified, .otherTarget] {
        #expect(PasteReadiness.decision(elapsed: 8, evidence: evidence) == .timedOut)
    }
}
