import Testing
@testable import Q2CApp

@Test func outsideClickIsCancelledAndPairedReleaseIsSwallowedAfterClose() {
    var policy = PickerClickPolicy()
    let press = policy.filter(button: 0, down: true, up: false, outside: true)
    #expect(press.swallow && press.cancel)
    policy.selecting = false
    #expect(policy.filter(button: 0, down: false, up: false, outside: false).swallow)
    let release = policy.filter(button: 0, down: false, up: true, outside: false)
    #expect(release.swallow && !release.cancel)
    #expect(policy.swallowedButton == nil)
    #expect(!policy.filter(button: 0, down: true, up: false, outside: true).swallow)
}

@Test func insideSelectionAndUnrelatedButtonsPassThrough() {
    var policy = PickerClickPolicy()
    #expect(!policy.filter(button: 0, down: true, up: false, outside: false).swallow)
    #expect(!policy.filter(button: 0, down: false, up: true, outside: false).swallow)
    #expect(policy.filter(button: 1, down: true, up: false, outside: true).cancel)
    #expect(!policy.filter(button: 0, down: true, up: false, outside: true).swallow)
    #expect(policy.filter(button: 1, down: false, up: true, outside: true).swallow)
}
