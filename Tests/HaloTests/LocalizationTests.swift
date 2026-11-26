import Testing
@testable import halo

@MainActor
struct LocalizationTests {
    @Test func koreanIsUsedOnlyWhenItIsTheFirstPreferredLanguage() {
        #expect(AppLanguage.resolve(["ko-KR", "en-US"]) == .korean)
        #expect(AppLanguage.resolve(["en-US", "ko-KR"]) == .english)
        #expect(AppLanguage.resolve(["ja-JP"]) == .english)
        #expect(AppLanguage.resolve([]) == .english)
    }

    @Test func stringsFollowTheCurrentLanguage() {
        let saved = AppLanguage.current
        defer { AppLanguage.current = saved }
        AppLanguage.current = .english
        #expect(BrightnessKeyTargetMode.allDisplays.title == "All Displays")
        #expect(VirtualDisplayPreset.portrait9x16.label == "9:16 (Portrait HiDPI)")
        AppLanguage.current = .korean
        #expect(BrightnessKeyTargetMode.allDisplays.title == "모든 화면")
    }
}
