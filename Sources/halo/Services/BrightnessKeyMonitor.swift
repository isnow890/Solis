import AppKit
import ApplicationServices

final class BrightnessKeyMonitor: NSObject {
    enum StepDirection { case up, down }
    struct Status: Equatable {
        var accessibility = AXIsProcessTrusted()
        var postEvent = CGPreflightPostEventAccess()
        var enabled = false
        var mask: CGEventMask = 0
        var ready: Bool { enabled && mask & requiredMask == requiredMask }
        var needsAdditionalPermission: Bool { accessibility && !postEvent && !ready }
        var needsRelaunch: Bool { accessibility && postEvent && !ready }
    }

    static var permissionExplanation: String { L("다른 앱을 쓰는 동안에도 밝기 키를 눌러 모니터를 조절하려면 macOS 권한이 필요합니다. halo는 키 입력을 이 Mac에서 밝기 단축키를 구분하는 데만 사용합니다.", "halo needs macOS permission to adjust your displays with the brightness keys while another app is active. It checks key events on this Mac only to recognize brightness shortcuts.") }

    static let requiredMask: CGEventMask = (1 << 14) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
    static let standardKeysPreference = "halo.captureStandardFunctionKeys"
    static let ctrlOptionArrowsPreference = "halo.captureCtrlOptionArrows"

    static var standardKeysDefault: Bool {
        let defaults = UserDefaults.standard
        if let value = defaults.object(forKey: standardKeysPreference) as? Bool { return value }
        return defaults.bool(forKey: "com.apple.keyboard.fnState")
    }

    static var ctrlOptionArrowsDefault: Bool {
        let defaults = UserDefaults.standard
        if let value = defaults.object(forKey: ctrlOptionArrowsPreference) as? Bool { return value }
        return false
    }

    var captureStandardKeys = standardKeysDefault
    var captureCtrlOptionArrows = ctrlOptionArrowsDefault
    var onBrightnessStep: ((StepDirection, Bool, CGDirectDisplayID?) -> Void)?
    var onStatus: ((Status) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var poll: Timer?
    private var fastPollDeadline: ContinuousClock.Instant?
    private var stopped = false
    private var observingPermission = false
    private static let permissionNotification = Notification.Name("com.apple.accessibility.api")
    private var retryInterval = 1.5
    private var consumed = [Int64: StepDirection]()

    /// Inspect only. In CLI mode a running app's tap and the CLI process's TCC preflight are separate observations.
    static func tapInfo(pid: pid_t) -> CGEventTapInformation? {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return nil }
        var list = [CGEventTapInformation](repeating: .init(), count: Int(count))
        guard CGGetEventTapList(count, &list, &count) == .success else { return nil }
        return list.prefix(Int(count)).first {
            $0.tappingProcess == pid && $0.tapPoint == .cgSessionEventTap &&
            $0.options == .defaultTap && $0.eventsOfInterest != 0 &&
            $0.eventsOfInterest & ~requiredMask == 0
        }
    }

    static func requestAccessibilityPermission() {
        if !AXIsProcessTrusted() {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        if !CGPreflightPostEventAccess() {
            _ = CGRequestPostEventAccess()
        }
        openAccessibilitySettings()
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func start() {
        guard !stopped, !observingPermission else { return }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(permissionChanged(_:)),
            name: Self.permissionNotification, object: nil, suspensionBehavior: .deliverImmediately)
        observingPermission = true
        refresh()
    }

    @objc private func permissionChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.beginFastPolling() }
    }

    /// Polls every 1 second for 60 seconds right after the user clicks "권한 허용" so returning from Settings feels instant.
    func beginFastPolling(duration: TimeInterval = 60) {
        guard !stopped else { return }
        fastPollDeadline = .now.advanced(by: .seconds(duration))
        retryInterval = 1.0
        refresh()
    }

    func refresh() {
        guard !stopped else { return }
        poll?.invalidate()
        var status = currentStatus()
        if !status.ready || !status.accessibility {
            removeTap()
            // Creating an active tap may prompt on first launch. Only probe an authorized process.
            if status.accessibility && status.postEvent { installTap() }
            status = currentStatus()
        }
        onStatus?(status)

        guard !stopped else { return }
        let interval: TimeInterval
        if status.ready {
            fastPollDeadline = nil
            retryInterval = 1.5
            interval = 15
        } else if let deadline = fastPollDeadline, .now < deadline {
            interval = 1.0
        } else {
            fastPollDeadline = nil
            interval = retryInterval
            retryInterval = min(15, retryInterval * 1.6)
        }

        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    private func currentStatus() -> Status {
        var status = Status()
        if let tap, let info = Self.tapInfo(pid: getpid()) {
            status.enabled = CGEvent.tapIsEnabled(tap: tap) && info.enabled
            status.mask = info.eventsOfInterest
        }
        return status
    }

    private func installTap() {
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: Self.requiredMask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return Unmanaged<BrightnessKeyMonitor>.fromOpaque(context).takeUnretainedValue()
                    .handleEvent(type: type, event: event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        let runSource = CFMachPortCreateRunLoopSource(nil, port, 0)
        tap = port
        source = runSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    private func removeTap() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        consumed.removeAll()
    }

    func stop() {
        stopped = true
        if observingPermission {
            DistributedNotificationCenter.default().removeObserver(self, name: Self.permissionNotification, object: nil)
            observingPermission = false
        }
        poll?.invalidate()
        poll = nil
        fastPollDeadline = nil
        removeTap()
    }

    func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            consumed.removeAll()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.poll != nil else { return }
                self.refresh()
            }
            return pass
        }
        let flags = event.flags
        let fine = flags.contains([.maskAlternate, .maskShift])
        if type.rawValue == 14, let nx = NSEvent(cgEvent: event), nx.subtype.rawValue == 8 {
            let code = (nx.data1 >> 16) & 0xffff
            guard code == 2 || code == 3 else { return pass }
            if (nx.data1 >> 8) & 0xff == 0x0a {
                emit(code == 2 ? .up : .down, fine: fine)
            }
            return nil
        }

        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp { return consumed.removeValue(forKey: code) == nil ? pass : nil }
        guard type == .keyDown else { return pass }
        let direction: StepDirection
        if let held = consumed[code] {
            direction = held
        } else if captureCtrlOptionArrows,
                  flags.contains([.maskControl, .maskAlternate]), !flags.contains(.maskCommand),
                  code == 126 || code == 125 {
            direction = code == 126 ? .up : .down
        } else {
            let modifiers = flags.intersection([.maskControl, .maskCommand, .maskAlternate, .maskShift])
            guard modifiers.isEmpty || modifiers == [.maskAlternate, .maskShift] else { return pass }
            switch code {
            case 107: direction = .down
            case 113: direction = .up
            case 122 where captureStandardKeys: direction = .down
            case 120 where captureStandardKeys: direction = .up
            default: return pass
            }
        }
        consumed[code] = direction
        emit(direction, fine: fine)
        return nil
    }

    private func emit(_ direction: StepDirection, fine: Bool) {
        let id = DisplayTopology.screenUnderMouse()
        DispatchQueue.main.async { [weak self] in self?.onBrightnessStep?(direction, fine, id) }
    }

    deinit { stop() }
}
