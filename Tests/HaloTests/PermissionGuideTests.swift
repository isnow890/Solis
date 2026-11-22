import AppKit
import Testing
@testable import halo

@MainActor
struct PermissionGuideTests {
    typealias Status = BrightnessKeyMonitor.Status

    // Each test gets a fresh app preferences domain without touching macOS permissions.
    private func withPreferences(_ test: (UserDefaults, String) throws -> Void) rethrows {
        let name = "halo.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try test(defaults, name)
    }

    @Test func firstLaunchExplainsPermissionAndOffersLater() throws {
        try withPreferences { defaults, _ in
            let missing = Status(accessibility: false, postEvent: false)
            let alert = try #require(AppDelegate.initialPermissionAlert(for: missing, defaults: defaults))
            #expect(alert.messageText.contains("밝기"))
            #expect(alert.informativeText.contains("다른 앱"))
            #expect(alert.informativeText.contains("이 Mac에서 밝기 단축키"))
            #expect(alert.informativeText.contains("밝기와 해상도"))
            #expect(alert.buttons.map(\.title) == ["권한 설정 열기", "나중에"])
            #expect(alert.buttons.last?.keyEquivalent == "\u{1b}")
        }
    }

    @Test func guideStaysDismissedOnRelaunchWithoutPermission() {
        withPreferences { defaults, name in
            let missing = Status(accessibility: false, postEvent: false)
            #expect(AppDelegate.initialPermissionAlert(for: missing, defaults: defaults) != nil)
            let nextLaunch = UserDefaults(suiteName: name)!
            #expect(AppDelegate.initialPermissionAlert(for: missing, defaults: nextLaunch) == nil)
        }
    }

    @Test func existingInstallThatSawTheGuideIsNotPromptedAgain() {
        withPreferences { defaults, _ in
            defaults.set(true, forKey: "halo.didShowPermissionGuide")
            let missing = Status(accessibility: false, postEvent: false)
            #expect(AppDelegate.initialPermissionAlert(for: missing, defaults: defaults) == nil)
        }
    }

    @Test func authorizedLaunchDoesNotConsumeTheFirstGuide() {
        withPreferences { defaults, _ in
            let connected = Status(accessibility: true, postEvent: true, enabled: true, mask: BrightnessKeyMonitor.requiredMask)
            let waitingForConnection = Status(accessibility: true, postEvent: true)
            let missingPostEvent = Status(accessibility: true, postEvent: false)
            #expect(AppDelegate.initialPermissionAlert(for: connected, defaults: defaults) == nil)
            #expect(AppDelegate.initialPermissionAlert(for: waitingForConnection, defaults: defaults) == nil)
            #expect(AppDelegate.initialPermissionAlert(for: missingPostEvent, defaults: defaults) != nil)
        }
    }

    @Test func brightnessKeysRequireAnEnabledTapWithAllThreeEvents() {
        let requiredEvents: [CGEventMask] = [1 << 14, 1 << CGEventType.keyDown.rawValue, 1 << CGEventType.keyUp.rawValue]
        let fullMask = requiredEvents.reduce(0, |)
        var status = Status(accessibility: true, postEvent: true, enabled: true, mask: fullMask)
        #expect(status.ready)
        #expect(!status.needsRelaunch)
        for event in requiredEvents {
            status.mask = fullMask & ~event
            #expect(!status.ready)
            #expect(status.needsRelaunch)
        }
        status.mask = fullMask
        status.enabled = false
        #expect(!status.ready)
        #expect(status.needsRelaunch)
        status.postEvent = false
        #expect(status.needsAdditionalPermission)
        #expect(!status.needsRelaunch)
    }
}
