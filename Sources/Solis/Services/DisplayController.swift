import Foundation
import AppKit
import CoreGraphics
import ServiceManagement
import CDisplayBridge

private let displayChanged: CGDisplayReconfigurationCallBack = { _, flags, context in
    guard let context else { return }
    let controller = Unmanaged<DisplayController>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async { controller.configurationChanged(beginning: flags.contains(.beginConfigurationFlag)) }
}

@MainActor
final class DisplayController: ObservableObject {
    @Published private(set) var displays: [DisplayItem] = []
    @Published private(set) var cursorDisplayID: CGDirectDisplayID?
    @Published private(set) var virtualDisplays: [ManagedVirtualDisplayInfo] = []
    @Published private(set) var keyStatus = BrightnessKeyMonitor.Status()
    var isAccessibilityGranted: Bool { keyStatus.ready }
    @Published var captureStandardKeys = BrightnessKeyMonitor.standardKeysDefault {
        didSet {
            keyMonitor.captureStandardKeys = captureStandardKeys
            UserDefaults.standard.set(captureStandardKeys, forKey: BrightnessKeyMonitor.standardKeysPreference)
        }
    }
    @Published var popoverAvailableHeight: CGFloat = 720
    @Published private(set) var statusBannerMessage: String?

    @Published var keyTargetMode: BrightnessKeyTargetMode {
        didSet {
            UserDefaults.standard.set(keyTargetMode.rawValue, forKey: DefaultsKey.keyTargetMode)
        }
    }

    @Published var cleanupVirtualOnQuit: Bool {
        didSet {
            UserDefaults.standard.set(cleanupVirtualOnQuit, forKey: DefaultsKey.cleanupVirtualOnQuit)
        }
    }

    @Published private(set) var loginStatus = SMAppService.mainApp.status
    var launchAtLogin: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }
    var loginNeedsApproval: Bool { loginStatus == .requiresApproval }
    func refreshLoginStatus() { loginStatus = SMAppService.mainApp.status }
    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    let softwareDimmer = SoftwareDimmer()
    let virtualDisplayManager = VirtualDisplayManager()
    private var channels: [CGDirectDisplayID: DDCChannel] = [:]
    private var portQueues: [String: DispatchQueue] = [:]
    private var lastDDCLevel: [CGDirectDisplayID: Double] = [:]
    private var inputVersion: [CGDirectDisplayID: Int] = [:]
    private var hudGeneration = 0
    private var hudDisplay: CGDirectDisplayID?
    private var isShuttingDown = false
    private var topologyChanging = false
    private let osdController = BrightnessOSDController()
    private let keyMonitor = BrightnessKeyMonitor()

    private var cursorPollTimer: Timer?
    private var reconfigDebounceItem: DispatchWorkItem?
    private var reconfigRegistered = false
    private var lastNativeWriteTime: [CGDirectDisplayID: Date] = [:]

    // Continuous 120Hz exponential-damping brightness animator for silky smooth Native & Overlay ramps
    private var smoothTimer: CADisplayLink?
    private var ddcInFlight = Set<CGDirectDisplayID>()
    private var smoothLastTick: CFTimeInterval = 0
    private var smoothRenderedValue: [CGDirectDisplayID: Double] = [:]
    private var smoothTargetValue: [CGDirectDisplayID: Double] = [:]
    private var smoothTargetBackend: [CGDirectDisplayID: BrightnessBackend] = [:]

    private enum DefaultsKey {
        static let keyTargetMode = "Solis.keyTargetMode"
        static let cleanupVirtualOnQuit = "Solis.cleanupVirtualOnQuit"
        static let backendPrefix = "Solis.backend."
        static let softwareBrightnessPrefix = "Solis.swBrightness."
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: DefaultsKey.keyTargetMode),
           let mode = BrightnessKeyTargetMode(rawValue: raw) {
            self.keyTargetMode = mode
        } else {
            self.keyTargetMode = .mouseCursor
        }

        if UserDefaults.standard.object(forKey: DefaultsKey.cleanupVirtualOnQuit) != nil {
            self.cleanupVirtualOnQuit = UserDefaults.standard.bool(forKey: DefaultsKey.cleanupVirtualOnQuit)
        } else {
            self.cleanupVirtualOnQuit = true
        }

        setupKeyMonitor()
        registerDisplayReconfigurationCallback()
        refreshDisplays()
    }

    // MARK: - Key Monitor & Accessibility

    private func setupKeyMonitor() {
        keyMonitor.captureStandardKeys = captureStandardKeys
        keyMonitor.onStatus = { [weak self] in self?.keyStatus = $0 }
        keyMonitor.onBrightnessStep = { [weak self] direction, fine, desktop in
            self?.handleBrightnessHotkey(direction: direction, isFineStep: fine, desktop: desktop)
        }
        keyMonitor.refresh()
    }

    func requestAccessibilityPermission() {
        BrightnessKeyMonitor.requestAccessibilityPermission()
        refreshAccessibilityStatus()
    }

    func refreshAccessibilityStatus() {
        guard !isShuttingDown else { return }
        keyMonitor.refresh()
        refreshLoginStatus()
    }

    func relaunchApp() {
        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.arguments = ["--replacing-pid", String(getpid())]
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { [weak self] app, error in
            DispatchQueue.main.async {
                guard app != nil, error == nil else {
                    self?.showTemporaryMessage(error?.localizedDescription ?? "새 인스턴스를 시작하지 못했습니다.")
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLoginStatus()
        } catch {
            showTemporaryMessage("로그인 시 자동 실행 설정 실패: \(error.localizedDescription)")
            refreshLoginStatus()
        }
    }

    // MARK: - Cursor Tracking

    func startCursorTracking() {
        updateCursorDisplay()
        cursorPollTimer?.invalidate()
        cursorPollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateCursorDisplay()
            }
        }
    }

    func stopCursorTracking() {
        cursorPollTimer?.invalidate()
        cursorPollTimer = nil
    }

    private func updateCursorDisplay() {
        cursorDisplayID = DisplayTopology.screenUnderMouse().flatMap(resolvedTarget(for:))
    }

    // MARK: - Display Enumeration & Probing

    func refreshDisplays() {
        guard !isShuttingDown, !topologyChanging, let onlineIDs = DisplayTopology.onlineIDs() else { return }
        let previousByID = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        let virtualIDs = virtualDisplayManager.virtualDisplayIDSet()
        virtualDisplays = virtualDisplayManager.activeVirtualDisplays

        let ports = LDMatchedDDCPorts(onlineIDs.map { NSNumber(value: $0) })
        for (id, channel) in channels where !onlineIDs.contains(id) || ports[NSNumber(value: id)] != channel.port ||
            DisplayTopology.uuid(id) != channel.uuid {
            channel.invalidate()
            channels.removeValue(forKey: id)
            lastDDCLevel.removeValue(forKey: id)
            ddcInFlight.remove(id)
        }
        for item in displays where !onlineIDs.contains(item.id) || DisplayTopology.uuid(item.id) != item.uuidString {
            clearAnimation(for: item.id)
            softwareDimmer.removeOverlay(for: item.id)
            lastNativeWriteTime.removeValue(forKey: item.id)
            inputVersion.removeValue(forKey: item.id)
        }

        let screenByID: [CGDirectDisplayID: NSScreen] = Dictionary(
            uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                    return nil
                }
                return (id, screen)
            }
        )

        var builtItems: [DisplayItem] = []

        for displayID in onlineIDs {
            let screen = screenByID[displayID]
            let isBuiltIn = CGDisplayIsBuiltin(displayID) != 0
            let isMain = CGDisplayIsMain(displayID) != 0
            let isVirtual = virtualIDs.contains(displayID)
            let mirrorMaster = CGDisplayMirrorsDisplay(displayID)
            let isMirrored = CGDisplayIsInMirrorSet(displayID) != 0

            let vendorID = CGDisplayVendorNumber(displayID)
            let productID = CGDisplayModelNumber(displayID)
            let serialNumber = CGDisplaySerialNumber(displayID)
            let uuidString = DisplayTopology.uuid(displayID) ?? "display-\(vendorID)-\(productID)-\(displayID)"

            let name: String = {
                if let managed = virtualDisplays.first(where: { $0.displayID == displayID }) {
                    return managed.name
                }
                if let localized = screen?.localizedName, !localized.isEmpty {
                    return localized
                }
                if let old = previousByID[displayID], old.uuidString == uuidString { return old.name }
                return isBuiltIn ? "Built-in Display" : "External Display \(displayID)"
            }()

            let mode = CGDisplayCopyDisplayMode(displayID)
            let logicalW = mode?.width ?? Int(CGDisplayPixelsWide(displayID))
            let logicalH = mode?.height ?? Int(CGDisplayPixelsHigh(displayID))
            let pixelW = mode?.pixelWidth ?? logicalW
            let pixelH = mode?.pixelHeight ?? logicalH
            let scale = screen?.backingScaleFactor ?? (logicalW > 0 ? CGFloat(pixelW) / CGFloat(logicalW) : 1.0)
            let hz = mode?.refreshRate ?? 0
            let rotation = CGDisplayRotation(displayID)

            let previous = previousByID[displayID].flatMap { $0.uuidString == uuidString ? $0 : nil }
            let canNative = !isVirtual && LDDisplayServicesCanChangeBrightness(displayID)

            var supported: [BrightnessBackend] = []
            if canNative {
                supported.append(.native)
            }
            if channels[displayID] != nil, let prev = previous, prev.supportedBackends.contains(.ddc) {
                supported.append(.ddc)
            }
            supported.append(.softwareOverlay)
            supported.append(.softwareGamma)

            let savedBackend = loadPreferredBackend(uuid: uuidString)
            let activeBackend: BrightnessBackend = {
                if let saved = savedBackend, supported.contains(saved) {
                    return saved
                }
                if let prev = previous, supported.contains(prev.activeBackend) {
                    return prev.activeBackend
                }
                if canNative {
                    return .native
                }
                if supported.contains(.ddc) {
                    return .ddc
                }
                return .softwareOverlay
            }()

            var initialBrightness: Double = previous?.brightness ?? 1.0
            if activeBackend == .native {
                var nativeVal: Float = 0.5
                if smoothTargetValue[displayID] == nil, LDDisplayServicesGetBrightness(displayID, &nativeVal) {
                    initialBrightness = Double(nativeVal)
                }
            } else if activeBackend == .softwareOverlay || activeBackend == .softwareGamma {
                if let saved = loadSoftwareBrightness(uuid: uuidString) {
                    initialBrightness = saved
                }
            }

            let modeBundle = DisplayModeManager.listModes(for: displayID)

            let awaitingDDC = savedBackend == .ddc && !supported.contains(.ddc) &&
                ports[NSNumber(value: displayID)] != nil && LDIOAVServiceIsAvailable() && DisplayTopology.uuid(displayID) != nil
            let item = DisplayItem(
                id: displayID,
                uuidString: uuidString,
                name: name,
                vendorID: vendorID,
                productID: productID,
                serialNumber: serialNumber,
                isBuiltIn: isBuiltIn,
                isMain: isMain,
                isVirtual: isVirtual,
                isMirrored: isMirrored,
                mirrorMasterID: mirrorMaster != 0 ? mirrorMaster : nil,
                logicalWidth: logicalW,
                logicalHeight: logicalH,
                pixelWidth: pixelW,
                pixelHeight: pixelH,
                scaleFactor: scale,
                refreshRate: hz,
                rotation: rotation,
                brightness: min(max(initialBrightness, 0.0), 1.0),
                activeBackend: activeBackend,
                supportedBackends: supported,
                ddcState: channels[displayID] == nil ? "탐색 중" : previous?.ddcState ?? "탐색 중",
                awaitingPreferredDDC: awaitingDDC,
                ddcReadable: channels[displayID] != nil && previous?.ddcReadable == true,
                ddcMaxValue: previous?.ddcMaxValue ?? 100,
                modes: modeBundle.modes,
                currentResolutionRefreshModes: modeBundle.currentRefreshModes
            )

            builtItems.append(item)

            // Re-apply active software dimming if needed
            if activeBackend != .softwareOverlay { softwareDimmer.removeOverlay(for: displayID) }
            if activeBackend != .softwareGamma { _ = softwareDimmer.resetGamma(for: displayID) }
            if activeBackend == .softwareOverlay && !awaitingDDC && smoothTargetValue[displayID] == nil {
                softwareDimmer.setOverlayBrightness(item.brightness, for: displayID)
            } else if activeBackend == .softwareGamma && previous?.activeBackend != .softwareGamma {
                if !softwareDimmer.setGammaBrightness(item.brightness, for: displayID) {
                    showTemporaryMessage(item.name + " · 저장된 감마를 적용할 수 없습니다.")
                }
            }
        }

        // Sort: Main first, then Built-in, then External by name, Virtual last
        displays = builtItems.sorted { lhs, rhs in
            if lhs.isVirtual != rhs.isVirtual { return !lhs.isVirtual }
            if lhs.isMain != rhs.isMain { return lhs.isMain }
            if lhs.isBuiltIn != rhs.isBuiltIn { return lhs.isBuiltIn }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        softwareDimmer.syncOverlayFrames(online: Set(onlineIDs))
        updateCursorDisplay()

        // Probe Apple Silicon DDC/CI asynchronously for external non-built-in displays
        for item in displays where !item.isBuiltIn && !item.isVirtual {
            guard let port = ports[NSNumber(value: item.id)], LDIOAVServiceIsAvailable() else {
                if let i = displays.firstIndex(where: { $0.id == item.id }) { displays[i].ddcState = "고유 포트 없음" }
                continue
            }
            if channels[item.id] == nil {
                let queue = portQueues[port] ?? DispatchQueue(label: "com.isnow890.solis.ddc." + port, qos: .userInitiated)
                portQueues[port] = queue
                channels[item.id] = DDCChannel(id: item.id, uuid: item.uuidString, port: port, queue: queue)
            }
            if let channel = channels[item.id], !ddcInFlight.contains(item.id) {
                probeDDC(item, channel: channel)
            }
        }
    }

    private func probeDDC(_ item: DisplayItem, channel: DDCChannel) {
        let version = inputVersion[item.id, default: 0]
        channel.probe { [weak self, weak channel] reading in
            guard let self, let channel, self.channels[item.id] === channel,
                  let i = self.displays.firstIndex(where: { $0.uuidString == channel.uuid && $0.id == item.id })
            else { return }
            let wasWaiting = self.displays[i].awaitingPreferredDDC
            self.displays[i].awaitingPreferredDDC = false
            guard let reading else {
                self.displays[i].ddcState = "AVService 없음"
                if wasWaiting && self.displays[i].activeBackend == .softwareOverlay {
                    self.softwareDimmer.setOverlayBrightness(self.displays[i].brightness, for: item.id)
                }
                return
            }
            if !self.displays[i].supportedBackends.contains(.ddc) {
                self.displays[i].supportedBackends.insert(.ddc, at: 0)
            }
            guard !self.ddcInFlight.contains(item.id), self.inputVersion[item.id, default: 0] == version else { return }
            self.displays[i].ddcReadable = reading.fraction != nil
            self.displays[i].ddcState = reading.fraction == nil ? "쓰기 미검증 · " + reading.description : "읽기 확인"
            let saved = self.loadPreferredBackend(uuid: channel.uuid)
            let useDDC = saved == .ddc || (saved == nil && reading.fraction != nil &&
                !self.displays[i].supportedBackends.contains(.native))
            if useDDC && self.displays[i].activeBackend != .ddc {
                guard self.softwareDimmer.resetGamma(for: item.id) else { return }
                self.clearAnimation(for: item.id)
                self.softwareDimmer.removeOverlay(for: item.id)
                self.displays[i].activeBackend = .ddc
            }
            if let fraction = reading.fraction {
                self.displays[i].ddcMaxValue = reading.maximum
                self.lastDDCLevel[item.id] = fraction
                if self.displays[i].activeBackend == .ddc { self.displays[i].brightness = fraction }
            }
        }
    }

    // MARK: - Brightness Control

    func setBrightness(_ value: Double, for displayID: CGDirectDisplayID, showOSD: Bool = false, smooth: Bool = false) {
        guard !isShuttingDown, !topologyChanging, value.isFinite,
              let idx = displays.firstIndex(where: { $0.id == displayID }) else { return }
        guard !displays[idx].awaitingPreferredDDC else {
            showTemporaryMessage(displays[idx].name + " · 저장한 DDC 포트를 확인하고 있습니다.")
            return
        }
        let clamped = min(max(value, 0), 1)
        let item = displays[idx]
        inputVersion[displayID, default: 0] += 1
        if showOSD {
            hudGeneration += 1
            hudDisplay = displayID
        }
        if smoothTargetValue[displayID] == nil { smoothRenderedValue[displayID] = item.brightness }
        displays[idx].brightness = clamped
        if item.activeBackend == .ddc {
            writeDDC(clamped, item: item, showOSD: showOSD)
        } else if applyBrightness(clamped, item: item, smooth: smooth), showOSD {
            showHUD(item, level: clamped, badge: item.activeBackend.shortBadge)
        }
    }

    private func showHUD(_ item: DisplayItem, level: Double, badge: String) {
        osdController.show(displayID: item.id, displayName: item.name, backendBadge: badge, brightness: level)
    }

    private func writeDDC(_ level: Double, item: DisplayItem, showOSD: Bool) {
        let id = item.id
        guard let channel = channels[id], let i = displays.firstIndex(where: { $0.id == id }) else { return }
        let requested = UInt16((level * Double(item.ddcMaxValue)).rounded())
        displays[i].ddcState = "전송 중"
        ddcInFlight.insert(id)
        let hudTicket = hudGeneration
        if showOSD {
            showHUD(item, level: level, badge: item.ddcReadable ? "DDC/CI" : "DDC 미검증")
        }
        channel.write(requested, verify: item.ddcReadable) { [weak self, weak channel] result in
            guard let self, let channel, self.channels[id] === channel,
                  let i = self.displays.firstIndex(where: { $0.id == id && $0.activeBackend == .ddc })
            else { return }
            var reported = level
            var badge: String
            switch result {
            case .failed:
                reported = self.lastDDCLevel[id] ?? item.brightness
                badge = "DDC 전송 실패"
                self.showTemporaryMessage(item.name + " · " + badge)
            case .sent:
                badge = item.ddcReadable ? "DDC 확인 중" : "DDC 전송 · 미검증"
            case .readback(let reading):
                if let actual = reading.fraction {
                    self.lastDDCLevel[id] = actual
                    self.displays[i].ddcMaxValue = reading.maximum
                    reported = actual
                    badge = abs(level - actual) <= 0.5 / Double(reading.maximum) + 1e-9 ? "DDC 확인" : "DDC 장치값"
                } else {
                    badge = "DDC 재조회 실패"
                    self.showTemporaryMessage(item.name + " · " + reading.description)
                }
            }
            if case .sent = result {
                if !item.ddcReadable { self.ddcInFlight.remove(id) }
            } else {
                self.ddcInFlight.remove(id)
            }
            self.displays[i].ddcState = badge
            self.displays[i].brightness = reported
            let shouldUpdateHUD: Bool = {
                switch result {
                case .failed: return true
                case .sent: return false
                case .readback(let reading):
                    guard let actual = reading.fraction else { return true }
                    return abs(level - actual) > 0.5 / Double(reading.maximum) + 1e-9
                }
            }()
            if showOSD && shouldUpdateHUD && self.hudGeneration == hudTicket {
                self.showHUD(item, level: reported, badge: badge)
            }
        }
    }

    func switchBackend(_ backend: BrightnessBackend, for displayID: CGDirectDisplayID) {
        guard !isShuttingDown, !topologyChanging, let idx = displays.firstIndex(where: { $0.id == displayID }) else { return }
        guard displays[idx].supportedBackends.contains(backend) else { return }

        let oldBackend = displays[idx].activeBackend
        if oldBackend == backend && !displays[idx].awaitingPreferredDDC {
            savePreferredBackend(backend, uuid: displays[idx].uuidString)
            return
        }
        displays[idx].awaitingPreferredDDC = false

        if oldBackend == .softwareGamma && !softwareDimmer.resetGamma(for: displayID) {
            showTemporaryMessage("원래 감마를 복구하지 못했습니다.")
            return
        }
        clearAnimation(for: displayID)
        inputVersion[displayID, default: 0] += 1
        channels[displayID]?.cancelWrites()
        ddcInFlight.remove(displayID)
        // Reset previous software dimmer if switching away
        if oldBackend == .softwareOverlay {
            softwareDimmer.removeOverlay(for: displayID)
        }

        displays[idx].activeBackend = backend
        savePreferredBackend(backend, uuid: displays[idx].uuidString)

        if backend == .native {
            var val: Float = Float(displays[idx].brightness)
            if LDDisplayServicesGetBrightness(displayID, &val) {
                displays[idx].brightness = Double(val)
            }
        } else if backend == .ddc {
            if let known = lastDDCLevel[displayID] { displays[idx].brightness = known }
        } else {
            _ = applyBrightness(displays[idx].brightness, item: displays[idx])
        }
    }

    private func applyBrightness(_ clamped: Double, item: DisplayItem, smooth: Bool = false) -> Bool {
        switch item.activeBackend {
        case .native:
            if smooth && DisplayTopology.screen(for: item.id) != nil {
                enqueueSmoothBrightness(to: clamped, for: item.id, backend: .native)
            } else {
                cancelSmoothBrightness(for: item.id, finalValue: clamped)
                return writeNative(clamped, id: item.id)
            }

        case .ddc:
            return false

        case .softwareOverlay:
            guard DisplayTopology.screen(for: item.id) != nil else {
                if let i = displays.firstIndex(where: { $0.id == item.id }) { displays[i].brightness = item.brightness }
                showTemporaryMessage(item.name + " · 오버레이를 표시할 데스크톱이 없습니다.")
                return false
            }
            saveSoftwareBrightness(clamped, uuid: item.uuidString)
            if smooth {
                enqueueSmoothBrightness(to: clamped, for: item.id, backend: .softwareOverlay)
            } else {
                cancelSmoothBrightness(for: item.id, finalValue: clamped)
                softwareDimmer.setOverlayBrightness(clamped, for: item.id)
            }

        case .softwareGamma:
            cancelSmoothBrightness(for: item.id, finalValue: clamped)
            guard softwareDimmer.setGammaBrightness(clamped, for: item.id) else {
                if let i = displays.firstIndex(where: { $0.id == item.id }) { displays[i].brightness = item.brightness }
                showTemporaryMessage(item.name + " · 감마를 적용할 수 없습니다.")
                return false
            }
            saveSoftwareBrightness(clamped, uuid: item.uuidString)
        }
        return true
    }

    private func writeNative(_ value: Double, id: CGDirectDisplayID) -> Bool {
        guard LDDisplayServicesSetBrightness(id, Float(value)) else {
            var current: Float = 0
            if let i = displays.firstIndex(where: { $0.id == id }), LDDisplayServicesGetBrightness(id, &current) {
                displays[i].brightness = Double(current)
                if hudDisplay == id { showHUD(displays[i], level: Double(current), badge: "Native 실패") }
            }
            showTemporaryMessage("Native 밝기 쓰기에 실패했습니다.")
            return false
        }
        lastNativeWriteTime[id] = Date()
        return true
    }

    private func clearAnimation(for id: CGDirectDisplayID) {
        cancelSmoothBrightness(for: id, finalValue: 0)
        smoothRenderedValue.removeValue(forKey: id)
    }

    private func enqueueSmoothBrightness(to target: Double, for displayID: CGDirectDisplayID, backend: BrightnessBackend) {
        smoothTargetValue[displayID] = target
        smoothTargetBackend[displayID] = backend
        startSmoothTimerIfNeeded()
    }

    private func cancelSmoothBrightness(for displayID: CGDirectDisplayID, finalValue: Double) {
        smoothTargetValue.removeValue(forKey: displayID)
        smoothTargetBackend.removeValue(forKey: displayID)
        smoothRenderedValue[displayID] = finalValue
        if smoothTargetValue.isEmpty {
            smoothTimer?.invalidate()
            smoothTimer = nil
        }
    }

    private func startSmoothTimerIfNeeded() {
        guard smoothTimer == nil else { return }
        smoothLastTick = CACurrentMediaTime()
        guard let screen = smoothTargetValue.keys.compactMap(DisplayTopology.screen(for:))
            .max(by: { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond }) else { return }
        let link = screen.displayLink(target: self, selector: #selector(stepSmoothBrightness(_:)))
        let maximum = Float(min(120, max(1, screen.maximumFramesPerSecond)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(30, maximum), maximum: maximum, preferred: maximum)
        link.add(to: .main, forMode: .common)
        smoothTimer = link
    }

    @objc private func stepSmoothBrightness(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let dt = min(max(now - smoothLastTick, 1.0 / 240.0), 0.05)
        smoothLastTick = now

        // Exponential critically-damped smoothing (~140ms smooth tail, silky on 120Hz ProMotion)
        let blend = 1.0 - exp(-dt * 20.0)
        var finishedIDs: [CGDirectDisplayID] = []

        for (displayID, target) in smoothTargetValue {
            guard let backend = smoothTargetBackend[displayID] else {
                finishedIDs.append(displayID)
                continue
            }

            let current = smoothRenderedValue[displayID] ?? target
            let diff = target - current
            let next: Double
            if abs(diff) < 0.0012 {
                next = target
                finishedIDs.append(displayID)
            } else {
                next = current + diff * blend
            }

            smoothRenderedValue[displayID] = next

            switch backend {
            case .native:
                if next == target || Date().timeIntervalSince(lastNativeWriteTime[displayID] ?? .distantPast) >= 1.0 / 60 {
                    if !writeNative(next, id: displayID) { finishedIDs.append(displayID) }
                }
            case .softwareOverlay:
                softwareDimmer.setOverlayBrightness(next, for: displayID)
            default:
                break
            }
        }

        for id in finishedIDs {
            smoothTargetValue.removeValue(forKey: id)
            smoothTargetBackend.removeValue(forKey: id)
            smoothRenderedValue.removeValue(forKey: id)
        }

        if smoothTargetValue.isEmpty {
            smoothTimer?.invalidate()
            smoothTimer = nil
        }
    }

    // MARK: - Brightness Hotkeys (Mouse Cursor Display!)

    private func handleBrightnessHotkey(direction: BrightnessKeyMonitor.StepDirection, isFineStep: Bool, desktop: CGDirectDisplayID?) {
        guard !isShuttingDown, !topologyChanging else { return }
        let step = isFineStep ? (1.0 / 64.0) : (1.0 / 16.0)
        let delta = (direction == .up) ? step : -step

        switch keyTargetMode {
        case .mouseCursor:
            guard let desktop, let targetID = resolvedTarget(for: desktop) else { return }
            adjustSingleDisplay(targetID, delta: delta, showOSD: true)

        case .mainDisplay:
            guard let mainID = resolvedTarget(for: CGMainDisplayID()) else { return }
            adjustSingleDisplay(mainID, delta: delta, showOSD: true)

        case .allDisplays:
            let physicals = displays.filter { !$0.isVirtual }
            let underCursor = desktop.flatMap(resolvedTarget(for:))
            let hudTarget = physicals.first(where: { $0.id == underCursor })?.id ?? physicals.first?.id
            for item in physicals {
                adjustSingleDisplay(item.id, delta: delta, showOSD: item.id == hudTarget)
            }
        }
    }

    private func resolvedTarget(for desktop: CGDirectDisplayID) -> CGDirectDisplayID? {
        let root = DisplayTopology.desktopID(desktop)
        if let managed = virtualDisplays.first(where: { $0.displayID == root }),
           let physical = managed.mirroredPhysicalDisplayID, CGDisplayMirrorsDisplay(physical) == root {
            return physical
        }
        // Ordinary mirror groups share one cursor. Prefer their physical master.
        return displays.first { $0.id == root && !$0.isVirtual }?.id ??
            displays.first { !$0.isVirtual && $0.mirrorMasterID == root }?.id ??
            displays.first { $0.id == desktop }?.id
    }

    private func adjustSingleDisplay(_ displayID: CGDirectDisplayID, delta: Double, showOSD: Bool) {
        guard let idx = displays.firstIndex(where: { $0.id == displayID }) else { return }

        // Only resync from DisplayServices if enough time passed since our own write
        // (prevents reading stale mid-ramp values that cause visible brightness bounce/flicker)
        if displays[idx].activeBackend == .native {
            let elapsed = lastNativeWriteTime[displayID].map { Date().timeIntervalSince($0) } ?? 10.0
            if elapsed > 0.8 && smoothTargetValue[displayID] == nil {
                var currentNative: Float = Float(displays[idx].brightness)
                if LDDisplayServicesGetBrightness(displayID, &currentNative) {
                    displays[idx].brightness = Double(currentNative)
                    smoothRenderedValue[displayID] = Double(currentNative)
                }
            }
        }

        let nextVal = min(max(displays[idx].brightness + delta, 0.0), 1.0)
        setBrightness(nextVal, for: displayID, showOSD: showOSD, smooth: true)
    }

    // MARK: - Resolution & HiDPI

    func applyDisplayMode(_ mode: DisplayModeItem, for displayID: CGDirectDisplayID) {
        guard !isShuttingDown, !topologyChanging else { return }
        let ok = DisplayModeManager.applyMode(mode, to: displayID)
        if !ok {
            showTemporaryMessage("해상도 전환에 실패했습니다.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.refreshDisplays()
        }
    }

    func toggleVirtualHiDPIMirror(for display: DisplayItem) {
        guard !isShuttingDown, !topologyChanging else { return }
        if let record = virtualDisplayManager.mirrorRecord(forPhysicalDisplayID: display.id) {
            guard virtualDisplayManager.removeVirtualDisplay(id: record.id) else {
                showTemporaryMessage("기존 미러 관계를 복원하지 못했습니다. 다시 시도하세요.")
                return
            }
            showTemporaryMessage("\(display.name) 가상 HiDPI 미러링 해제됨")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.refreshDisplays()
            }
        } else {
            guard virtualDisplayManager.isSupported else {
                showTemporaryMessage("현재 macOS에서 CGVirtualDisplay를 사용할 수 없습니다.")
                return
            }
            virtualDisplayManager.enableHiDPIMirror(for: display) { [weak self] ok in
                Task { @MainActor in
                    if ok {
                        self?.showTemporaryMessage("\(display.name) 가상 HiDPI 미러링 활성화됨")
                    } else {
                        self?.showTemporaryMessage("\(display.name) 가상 HiDPI 미러링 실패")
                    }
                    self?.refreshDisplays()
                }
            }
        }
    }

    func createStandaloneVirtualDisplay(preset: VirtualDisplayPreset) {
        let count = virtualDisplayManager.activeVirtualDisplays.count + 1
        let name = "Solis Virtual \(count)"
        let created = virtualDisplayManager.createVirtualDisplay(name: name, preset: preset) { [weak self] in
            self?.refreshDisplays()
        }
        if created != nil {
            showTemporaryMessage("\(name) (\(preset.rawValue)) 생성됨")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.refreshDisplays()
            }
        } else {
            showTemporaryMessage("가상 디스플레이 생성에 실패했습니다.")
        }
    }

    func removeVirtualDisplay(id: UUID) {
        guard virtualDisplayManager.removeVirtualDisplay(id: id) else {
            showTemporaryMessage("미러 관계 복원 실패 · 가상 화면을 유지합니다.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.refreshDisplays()
        }
    }

    func exportDisplayOverridePlist(for display: DisplayItem) {
        let quarterTurn = Int(display.rotation.rounded()) % 180 != 0
        let baseW = quarterTurn ? display.logicalHeight : display.logicalWidth
        let baseH = quarterTurn ? display.logicalWidth : display.logicalHeight
        guard baseW > 0, baseH > 0 else { showTemporaryMessage("화면 크기를 확인할 수 없습니다."); return }
        let aspect = Double(baseW) / Double(max(baseH, 1))
        let candidates: [(Int, Int)] = [
            (baseW, baseH),
            ((Int(Double(baseW) * 0.85) / 2) * 2, (Int(Double(baseW) * 0.85 / aspect) / 2) * 2),
            ((Int(Double(baseW) * 0.75) / 2) * 2, (Int(Double(baseW) * 0.75 / aspect) / 2) * 2)
        ]

        guard let override = DisplayModeManager.generateDisplayOverridePlist(
            vendorID: display.vendorID,
            productID: display.productID,
            displayName: display.name,
            logicalResolutions: candidates
        ) else {
            showTemporaryMessage("Override plist 생성 실패")
            return
        }

        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = desktop.appendingPathComponent("Solis-Overrides/\(override.directoryName)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let fileURL = folder.appendingPathComponent(override.fileName)
            try override.data.write(to: fileURL, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            showTemporaryMessage("패널 기본 방향 \(baseW)×\(baseH) 기준으로 저장했습니다. 모드 채택은 드라이버에 따라 다릅니다.")
        } catch {
            showTemporaryMessage("Override 저장 실패: \(error.localizedDescription)")
        }
    }

    // MARK: - Display Reconfiguration Callback

    private func registerDisplayReconfigurationCallback() {
        guard !reconfigRegistered else { return }
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        reconfigRegistered = CGDisplayRegisterReconfigurationCallback(displayChanged, pointer) == .success
        if !reconfigRegistered { showTemporaryMessage("화면 구성 변경 감지를 등록하지 못했습니다.") }
    }

    fileprivate func configurationChanged(beginning: Bool) {
        guard !isShuttingDown else { return }
        topologyChanging = true
        for channel in channels.values { channel.invalidate() }
        channels.removeAll()
        ddcInFlight.removeAll()
        lastDDCLevel.removeAll()
        for id in Array(smoothRenderedValue.keys) { clearAnimation(for: id) }
        reconfigDebounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.topologyChanging = false
            self?.refreshDisplays()
        }
        reconfigDebounceItem = item
        // A cancelled WindowServer transaction may deliver only begin notifications.
        DispatchQueue.main.asyncAfter(deadline: .now() + (beginning ? 1.0 : 0.35), execute: item)
    }

    // MARK: - Shutdown Cleanup

    func cleanupOnTerminate() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        if reconfigRegistered {
            CGDisplayRemoveReconfigurationCallback(displayChanged, Unmanaged.passUnretained(self).toOpaque())
            reconfigRegistered = false
        }
        reconfigDebounceItem?.cancel()
        for channel in channels.values { channel.invalidate() }
        channels.removeAll()
        for queue in portQueues.values { queue.sync {} }
        osdController.close()
        virtualDisplayManager.cancelPending()
        stopCursorTracking()
        keyMonitor.stop()
        smoothTimer?.invalidate()
        smoothTimer = nil
        smoothTargetValue.removeAll()
        smoothTargetBackend.removeAll()
        softwareDimmer.resetAll()
        if cleanupVirtualOnQuit {
            virtualDisplayManager.removeAll()
        }
    }

    // MARK: - Persistence & Helpers

    private func loadPreferredBackend(uuid: String) -> BrightnessBackend? {
        guard let raw = UserDefaults.standard.string(forKey: DefaultsKey.backendPrefix + uuid) else {
            return nil
        }
        return BrightnessBackend(rawValue: raw)
    }

    private func savePreferredBackend(_ backend: BrightnessBackend, uuid: String) {
        UserDefaults.standard.set(backend.rawValue, forKey: DefaultsKey.backendPrefix + uuid)
    }

    private func loadSoftwareBrightness(uuid: String) -> Double? {
        let key = DefaultsKey.softwareBrightnessPrefix + uuid
        guard UserDefaults.standard.object(forKey: key) != nil else { return nil }
        return UserDefaults.standard.double(forKey: key)
    }

    private func saveSoftwareBrightness(_ value: Double, uuid: String) {
        UserDefaults.standard.set(value, forKey: DefaultsKey.softwareBrightnessPrefix + uuid)
    }

    private func showTemporaryMessage(_ msg: String) {
        statusBannerMessage = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            if self?.statusBannerMessage == msg {
                self?.statusBannerMessage = nil
            }
        }
    }
}
