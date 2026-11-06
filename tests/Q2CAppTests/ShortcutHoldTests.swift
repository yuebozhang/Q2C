import Testing
import Q2CCore
@testable import Q2CApp

@Test func chooserFavoriteComesFirstWithoutChangingSettingsOrder() {
    let first = ForwardProfile(targetLink: "codex://threads/11111111-1111-4111-8111-111111111111")
    let favorite = ForwardProfile(targetLink: "codex://threads/22222222-2222-4222-8222-222222222222", isFavorite: true)
    let last = ForwardProfile(targetLink: first.targetLink)
    let settings = [first, favorite, last]
    #expect(ShortcutTargets.ordered(settings).map(\.id) == [favorite.id, first.id, last.id])
    #expect(settings.map(\.id) == [first.id, favorite.id, last.id])
}

@Test func chooserWithoutFavoriteDefaultsToFirstValidProfile() {
    let invalid = ForwardProfile()
    let valid = ForwardProfile(targetLink: "codex://threads/11111111-1111-4111-8111-111111111111")
    #expect(ShortcutTargets.ordered([invalid, valid]).map(\.id) == [valid.id])
    #expect(ShortcutTargets.ordered([invalid]).isEmpty)
}
