import Foundation
import Testing
@testable import Q2CApp

@Test @MainActor func pickerCancellationRestoresSourceOnlyWhileQ2CIsForeground() {
    var activated: [pid_t] = []
    PickerFocusRestoration.restore(sourcePID: 1234, ownPID: 5678,
        frontmostPID: { 5678 }, activate: { activated.append($0); return true })
    #expect(activated == [1234])
}

@Test @MainActor func pickerCancellationDoesNotStealFocusOrActivateInvalidSource() {
    for (source, foreground): (pid_t?, pid_t?) in [(1234, 9999), (1234, nil), (nil, 5678), (5678, 5678)] {
        var activated = false
        PickerFocusRestoration.restore(sourcePID: source, ownPID: 5678,
            frontmostPID: { foreground }, activate: { _ in activated = true; return true })
        #expect(!activated)
    }
}
