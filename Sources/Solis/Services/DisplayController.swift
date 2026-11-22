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
    @Published private(set) var mirrorStates: [CGDirectDisplayID: VirtualMirrorState] = [:]
    @Published private(set) var pendingModeRevert: PendingModeRevert?
    @Published private(set) var keyStatus = BrightnessKeyMonitor.Status()
    @Published private(set) var statusBanner: StatusBanner?
    @Published var showSettingsInPopover: Bool = false

    var isAccessibilityGranted: Bool { keyStatus.ready }
    @Published var permissionBannerDeferred = false
    private var waitingForFirstConnection = false
    private var announcedKeyConnection = false

    var needsPermissionRelaunch: Bool { keyStatus.needsRelaunch }

    @Published var captureStandardKeys = BrightnessKeyMonitor.standardKeysDefault {
        didSet {
            keyMonitor.captureStandardKeys = captureStandardKeys
            UserDefaults.standard.set(captureStandardKeys, forKey: BrightnessKeyMonitor.standardKeysPreference)
        }
    }

    @Published var captureCtrlOptionArrows = BrightnessKeyMonitor.ctrlOptionArrowsDefault {
        didSet {
            keyMonitor.captureCtrlOptionArrows = captureCtrlOptionArrows
            UserDefaults.standard.set(captureCtrlOptionArrows, forKey: BrightnessKeyMonitor.ctrlOptionArrowsPreference)
        }
    }

    @Published var popoverAvailableHeight: CGFloat = 720

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

    /// Displays shown as cards in the popover (hides internal Solis virtual displays that are mirroring a physical display).
    var visibleDisplays: [DisplayItem] {
        let mirroredVirtualIDs = Set(virtualDisplays.compactMap { v -> CGDirectDisplayID? in
            v.mirroredPhysicalDisplayID != nil ? v.displayID : nil
        })
        return displays.filter { !mirroredVirtualIDs.contains($0.id) }
    }

    /// Standalone virtual displays (excluding ones attached as physical HiDPI mirrors).
    var standaloneVirtualDisplays: [ManagedVirtualDisplayInfo] {
        virtualDisplays.filter { $0.mirroredPhysicalDisplayID == nil }
    }

    /// Display IDs currently targeted by keyboard brightness keys (P0-3).
    func isKeyTarget(_ displayID: CGDirectDisplayID) -> Bool {
        guard keyStatus.ready else { return false }
        switch keyTargetMode {
        case .mouseCursor:
            return cursorDisplayID == displayID
        case .mainDisplay:
            return resolvedTarget(for: CGMainDisplayID()) == displayID
        case .allDisplays:
            return visibleDisplays.contains { $0.id == displayID && !$0.isVirtual }
        }
    }

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
    private var bannerDismissItem: DispatchWorkItem?
    private var identifyWorkItem: DispatchWorkItem?
    private var identifyOwner: (id: CGDirectDisplayID, uuid: String)?
    private var revertTimer: Timer?
    private var reconfigRegistered = false
    private var lastNativeWriteTime: [CGDirectDisplayID: ContinuousClock.Instant] = [:]

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
        keyMonitor.captureCtrlOptionArrows = captureCtrlOptionArrows
        keyMonitor.onStatus = { [weak self] status in
            guard let self else { return }
            if !status.ready { self.waitingForFirstConnection = true }
            if status.accessibility && self.permissionBannerDeferred { self.permissionBannerDeferred = false }
            self.keyStatus = status
            self.announceConnectionIfVisible()
        }
        keyMonitor.onBrightnessStep = { [weak self] direction, fine, desktop in
            self?.handleBrightnessHotkey(direction: direction, isFineStep: fine, desktop: desktop)
        }
        keyMonitor.start()
    }

    private func announceConnectionIfVisible() {
        guard cursorPollTimer != nil, waitingForFirstConnection, keyStatus.ready, !announcedKeyConnection else { return }
        announcedKeyConnection = true
        showBanner(.success, "키보드 밝기 키가 연결되었습니다 — 이제 밝기 키를 눌러 보세요.")
    }

    func requestAccessibilityPermission() {
        BrightnessKeyMonitor.requestAccessibilityPermission()
        keyMonitor.beginFastPolling(duration: 60)
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
                    self?.showBanner(.error, error?.localizedDescription ?? "새 인스턴스를 시작하지 못했습니다.")
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
            showBanner(.error, "로그인 시 자동 실행을 변경하지 못했습니다: \(error.localizedDescription)")
            refreshLoginStatus()
        }
    }

    // MARK: - Cursor Tracking & Hover Identification

    func startCursorTracking() {
        updateCursorDisplay()
        cursorPollTimer?.invalidate()
        cursorPollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateCursorDisplay()
            }
        }
        announceConnectionIfVisible()
    }

    func stopCursorTracking() {
        cursorPollTimer?.invalidate()
        cursorPollTimer = nil
        clearIdentify()
    }

    private func updateCursorDisplay() {
        cursorDisplayID = DisplayTopology.screenUnderMouse().flatMap(resolvedTarget(for:))
    }

    func scheduleIdentifyDisplay(_ display: DisplayItem) {
        guard cursorPollTimer != nil, !topologyChanging, visibleDisplays.count > 1 else { return }
        clearIdentify()
        let id = display.id
        let uuid = display.uuidString
        identifyOwner = (id, uuid)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.cursorPollTimer != nil, !self.topologyChanging,
                  self.identifyOwner?.id == id, self.identifyOwner?.uuid == uuid,
                  DisplayTopology.uuid(id) == uuid, self.visibleDisplays.count > 1,
                  let current = self.visibleDisplays.first(where: { $0.id == id && $0.uuidString == uuid }) else { return }
            self.osdController.showIdentify(displayID: id, displayName: current.name)
        }
        identifyWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
    }

    func clearIdentify(for display: DisplayItem? = nil) {
        if let display, identifyOwner?.id != display.id || identifyOwner?.uuid != display.uuidString { return }
        identifyOwner = nil
        identifyWorkItem?.cancel()
        identifyWorkItem = nil
        osdController.hideIfIdentify()
    }

    // MARK: - Display Enumeration & Probing

    func refreshDisplays() {
        guard !isShuttingDown, !topologyChanging, let onlineIDs = DisplayTopology.onlineIDs() else { return }
        let previousByID = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        virtualDisplayManager.reconcileMirrors(online: Set(onlineIDs))
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
            mirrorStates.removeValue(forKey: item.id)
        }

        let screenByID: [CGDirectDisplayID: NSScreen] = Dictionary(
            uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
                guard let id = DisplayTopology.screenID(screen) else { return nil }
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
                if let localized = screenByID[displayID]?.localizedName, !localized.isEmpty {
                    return localized
                }
                if let old = previousByID[displayID], old.uuidString == uuidString { return old.name }
                return isBuiltIn ? "내장 디스플레이" : "외장 디스플레이 \(displayID)"
            }()

            let mode = CGDisplayCopyDisplayMode(displayID)
            let logicalW = mode?.width ?? Int(CGDisplayPixelsWide(displayID))
            let logicalH = mode?.height ?? Int(CGDisplayPixelsHigh(displayID))
            let pixelW = mode?.pixelWidth ?? logicalW
            let pixelH = mode?.pixelHeight ?? logicalH
            let scale = screen?.backingScaleFactor ?? (logicalW > 0 ? CGFloat(pixelW) / CGFloat(logicalW) : 1.0)
            let hz = mode?.refreshRate ?? 0
            let rotation = CGDisplayRotation(displayID)
            let frameMinX = DisplayTopology.screen(for: displayID)?.frame.minX ?? CGDisplayBounds(displayID).minX

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
            var item = DisplayItem(
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
                frameMinX: frameMinX,
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
                ddcUserStatus: channels[displayID] == nil ? "확인 중" : (previous?.ddcUserStatus ?? "확인 중"),
                ddcTechnicalDetail: previous?.ddcTechnicalDetail ?? "",
                awaitingPreferredDDC: awaitingDDC,
                ddcReadable: channels[displayID] != nil && previous?.ddcReadable == true,
                ddcMaxValue: channels[displayID] == nil ? 100 : (previous?.ddcMaxValue ?? 100),
                modes: modeBundle.modes,
                currentResolutionRefreshModes: modeBundle.currentRefreshModes,
                inlineError: previous?.inlineError
            )

            // Sync mirror state with VirtualDisplayManager
            if let record = virtualDisplayManager.mirrorRecord(forPhysicalDisplayID: displayID) {
                mirrorStates[displayID] = virtualDisplayManager.isPending(record.id) ? .connecting : .active
            } else if mirrorStates[displayID]?.isActive == true || mirrorStates[displayID]?.isConnecting == true {
                mirrorStates[displayID] = .idle
            }

            if activeBackend != .softwareOverlay { softwareDimmer.removeOverlay(for: displayID) }
            if activeBackend != .softwareGamma { _ = softwareDimmer.resetGamma(for: displayID) }
            if activeBackend == .softwareOverlay && !awaitingDDC && smoothTargetValue[displayID] == nil {
                softwareDimmer.setOverlayBrightness(item.brightness, for: displayID)
            } else if activeBackend == .softwareGamma && previous?.activeBackend != .softwareGamma {
                if !softwareDimmer.setGammaBrightness(item.brightness, for: displayID) {
                    item.inlineError = "저장된 감마 밝기를 적용하지 못했습니다."
                }
            }
            builtItems.append(item)
        }

        // Sort physically left-to-right (frameMinX) so cards match desk layout; virtual screens last.
        displays = builtItems.sorted { lhs, rhs in
            if lhs.isVirtual != rhs.isVirtual { return !lhs.isVirtual }
            if lhs.frameMinX != rhs.frameMinX { return lhs.frameMinX < rhs.frameMinX }
            if lhs.isMain != rhs.isMain { return lhs.isMain }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        if pendingModeRevert != nil { _ = currentPreview() }
        softwareDimmer.syncOverlayFrames(online: Set(onlineIDs))
        updateCursorDisplay()

        // Probe Apple Silicon DDC/CI asynchronously for external non-built-in displays
        for item in displays where !item.isBuiltIn && !item.isVirtual {
            guard let port = ports[NSNumber(value: item.id)], LDIOAVServiceIsAvailable() else {
                if let i = displays.firstIndex(where: { $0.id == item.id }) {
                    displays[i].ddcUserStatus = "직접 제어 미지원"
                    displays[i].ddcTechnicalDetail = "직접 제어용 외부 포트(AVService)를 찾지 못했습니다."
                }
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
            guard let self, let channel, self.channels[item.id] === channel, DisplayTopology.uuid(item.id) == channel.uuid,
                  let i = self.displays.firstIndex(where: { $0.uuidString == channel.uuid && $0.id == item.id })
            else { return }
            let wasWaiting = self.displays[i].awaitingPreferredDDC
            self.displays[i].awaitingPreferredDDC = false
            guard let reading else {
                self.displays[i].ddcUserStatus = "직접 제어 미지원"
                self.displays[i].ddcTechnicalDetail = "포트(\(channel.port))에서 DDC 통신 채널을 열지 못했습니다."
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
            if let fraction = reading.fraction {
                self.displays[i].ddcUserStatus = "연결됨"
                self.displays[i].ddcTechnicalDetail = "포트 \(channel.port) · \(reading.description)"
                self.displays[i].ddcMaxValue = reading.maximum
                self.lastDDCLevel[item.id] = fraction
            } else {
                self.displays[i].ddcUserStatus = "응답 없음"
                self.displays[i].ddcTechnicalDetail = "포트 \(channel.port) · \(reading.description) (소프트웨어 디밍 권장)"
            }
            let saved = self.loadPreferredBackend(uuid: channel.uuid)
            let useDDC = saved == .ddc || (saved == nil && reading.fraction != nil &&
                !self.displays[i].supportedBackends.contains(.native))
            if useDDC && self.displays[i].activeBackend != .ddc {
                guard self.softwareDimmer.resetGamma(for: item.id) else { return }
                self.clearAnimation(for: item.id)
                self.softwareDimmer.removeOverlay(for: item.id)
                self.displays[i].activeBackend = .ddc
            }
            if let fraction = reading.fraction, self.displays[i].activeBackend == .ddc {
                self.displays[i].brightness = fraction
            }
        }
    }

    // MARK: - Brightness Control

    func setBrightness(
        _ value: Double,
        for displayID: CGDirectDisplayID,
        showOSD: Bool = false,
        smooth: Bool = false,
        osdTitleOverride: String? = nil
    ) {
        guard !isShuttingDown, !topologyChanging, value.isFinite,
              let idx = displays.firstIndex(where: { $0.id == displayID }) else { return }
        guard !displays[idx].awaitingPreferredDDC else {
            setInlineError("모니터 직접 제어 연결을 확인하는 중입니다.", for: displayID)
            return
        }
        let clamped = min(max(value, 0), 1)
        let item = displays[idx]
        let hudTitle = osdTitleOverride ?? item.name
        displays[idx].inlineError = nil
        inputVersion[displayID, default: 0] += 1
        if showOSD {
            clearIdentify()
            hudGeneration += 1
            hudDisplay = displayID
        }
        if !showOSD && hudDisplay == displayID { hudDisplay = nil }
        if smoothTargetValue[displayID] == nil { smoothRenderedValue[displayID] = item.brightness }
        displays[idx].brightness = clamped

        let useSmooth = smooth && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if item.activeBackend == .ddc {
            writeDDC(clamped, item: item, showOSD: showOSD, hudTitle: hudTitle)
        } else if applyBrightness(clamped, item: item, smooth: useSmooth, showOSDError: showOSD, hudTitle: hudTitle), showOSD {
            osdController.show(displayID: item.id, displayName: hudTitle, warningBadge: nil, brightness: clamped)
        }
    }

    private func writeDDC(_ level: Double, item: DisplayItem, showOSD: Bool, hudTitle: String) {
        let id = item.id
        guard let channel = channels[id], let i = displays.firstIndex(where: { $0.id == id }) else { return }
        let requested = UInt16((level * Double(item.ddcMaxValue)).rounded())
        displays[i].ddcUserStatus = "적용 중"
        if lastDDCLevel[id] == nil { lastDDCLevel[id] = item.brightness }
        ddcInFlight.insert(id)
        let hudTicket = hudGeneration
        if showOSD {
            let warn = item.ddcReadable ? "적용 중" : "응답 미확인"
            osdController.show(displayID: item.id, displayName: hudTitle, warningBadge: warn, brightness: level)
        }
        channel.write(requested, verify: item.ddcReadable) { [weak self, weak channel] result in
            guard let self, let channel, self.channels[id] === channel,
                  let i = self.displays.firstIndex(where: { $0.id == id && $0.activeBackend == .ddc })
            else { return }
            var reported = level
            var warningBadge: String?
            switch result {
            case .failed:
                reported = self.lastDDCLevel[id] ?? item.brightness
                self.displays[i].ddcUserStatus = "전송 실패"
                self.displays[i].inlineError = "모니터 밝기 신호 전송에 실패했습니다. 소프트웨어 디밍으로 바꿔보세요."
                warningBadge = "모니터 응답 없음"
            case .sent:
                if !item.ddcReadable { self.lastDDCLevel[id] = level }
                self.displays[i].ddcUserStatus = item.ddcReadable ? "확인 중" : "신호 전송됨 (미확인)"
            case .readback(let reading):
                if let reading, let actual = reading.fraction {
                    self.lastDDCLevel[id] = actual
                    self.displays[i].ddcMaxValue = reading.maximum
                    reported = actual
                    self.displays[i].ddcUserStatus = "연결됨"
                    self.displays[i].ddcTechnicalDetail = "포트 \(channel.port) · \(reading.description)"
                    if abs(level - actual) > 0.5 / Double(reading.maximum) + 1e-9 {
                        warningBadge = "장치 밝기"
                        self.displays[i].ddcUserStatus = "요청값과 다름"
                    }
                    self.displays[i].inlineError = nil
                } else {
                    self.displays[i].ddcUserStatus = "확인 실패"
                    self.displays[i].ddcTechnicalDetail = "포트 \(channel.port) · " + (reading?.description ?? "디스플레이 연결 변경")
                    warningBadge = "상태 확인 실패"
                }
            }
            if case .sent = result {
                if !item.ddcReadable { self.ddcInFlight.remove(id) }
            } else {
                self.ddcInFlight.remove(id)
            }
            self.displays[i].brightness = reported
            if case .sent = result { return }
            if showOSD && self.hudGeneration == hudTicket {
                self.osdController.show(displayID: item.id, displayName: hudTitle, warningBadge: warningBadge, brightness: reported)
            }
        }
    }

    func switchBackend(_ backend: BrightnessBackend, for displayID: CGDirectDisplayID) {
        guard !isShuttingDown, !topologyChanging, let idx = displays.firstIndex(where: { $0.id == displayID }) else { return }
        guard displays[idx].supportedBackends.contains(backend) else { return }

        displays[idx].inlineError = nil
        let oldBackend = displays[idx].activeBackend
        if oldBackend == backend && !displays[idx].awaitingPreferredDDC {
            savePreferredBackend(backend, uuid: displays[idx].uuidString)
            return
        }
        displays[idx].awaitingPreferredDDC = false

        if oldBackend == .softwareGamma && !softwareDimmer.resetGamma(for: displayID) {
            setInlineError("원래 색 보정(감마)을 복구하지 못했습니다.", for: displayID)
            return
        }
        clearAnimation(for: displayID)
        inputVersion[displayID, default: 0] += 1
        channels[displayID]?.cancelWrites()
        ddcInFlight.remove(displayID)
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
            _ = applyBrightness(displays[idx].brightness, item: displays[idx], smooth: false, showOSDError: false, hudTitle: displays[idx].name)
        }
    }

    private func applyBrightness(
        _ clamped: Double,
        item: DisplayItem,
        smooth: Bool,
        showOSDError: Bool,
        hudTitle: String
    ) -> Bool {
        switch item.activeBackend {
        case .native:
            if smooth && DisplayTopology.screen(for: item.id) != nil {
                enqueueSmoothBrightness(to: clamped, for: item.id, backend: .native)
            } else {
                cancelSmoothBrightness(for: item.id, finalValue: clamped)
                return writeNative(clamped, id: item.id, hudTitle: hudTitle)
            }

        case .ddc:
            return false

        case .softwareOverlay:
            guard DisplayTopology.screen(for: item.id) != nil else {
                if let i = displays.firstIndex(where: { $0.id == item.id }) { displays[i].brightness = item.brightness }
                setInlineError("소프트웨어 디밍을 표시할 화면 영역이 없습니다.", for: item.id)
                if showOSDError {
                    osdController.show(displayID: item.id, displayName: hudTitle, warningBadge: "디밍 불가", brightness: item.brightness)
                }
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
                setInlineError("감마 디밍을 적용하지 못했습니다. 소프트웨어 디밍으로 바꿔보세요.", for: item.id)
                if showOSDError {
                    osdController.show(displayID: item.id, displayName: hudTitle, warningBadge: "감마 적용 실패", brightness: item.brightness)
                }
                return false
            }
            saveSoftwareBrightness(clamped, uuid: item.uuidString)
        }
        return true
    }

    private func writeNative(_ value: Double, id: CGDirectDisplayID, hudTitle: String? = nil) -> Bool {
        guard LDDisplayServicesSetBrightness(id, Float(value)) else {
            var current: Float = 0
            if let i = displays.firstIndex(where: { $0.id == id }) {
                if LDDisplayServicesGetBrightness(id, &current) { displays[i].brightness = Double(current) }
                displays[i].inlineError = "하드웨어 밝기를 변경하지 못했습니다."
                if hudDisplay == id {
                    osdController.show(displayID: id, displayName: hudTitle ?? displays[i].name, warningBadge: "밝기 변경 실패", brightness: displays[i].brightness)
                }
            }
            return false
        }
        lastNativeWriteTime[id] = .now
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
                if next == target || lastNativeWriteTime[displayID].map({ $0.duration(to: .now) >= .seconds(1.0 / 60) }) != false {
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
            adjustSingleDisplay(targetID, delta: delta, showOSD: true, osdTitleOverride: nil)

        case .mainDisplay:
            guard let mainID = resolvedTarget(for: CGMainDisplayID()) else { return }
            adjustSingleDisplay(mainID, delta: delta, showOSD: true, osdTitleOverride: nil)

        case .allDisplays:
            let physicals = visibleDisplays.filter { !$0.isVirtual }
            let underCursor = desktop.flatMap(resolvedTarget(for:))
            let hudTarget = physicals.first(where: { $0.id == underCursor })?.id ?? physicals.first?.id
            for item in physicals {
                adjustSingleDisplay(
                    item.id,
                    delta: delta,
                    showOSD: item.id == hudTarget,
                    osdTitleOverride: physicals.count > 1 ? "모든 화면" : nil
                )
            }
        }
    }

    private func resolvedTarget(for desktop: CGDirectDisplayID) -> CGDirectDisplayID? {
        let root = DisplayTopology.desktopID(desktop)
        if let managed = virtualDisplays.first(where: { $0.displayID == root }),
           let physical = managed.mirroredPhysicalDisplayID, CGDisplayMirrorsDisplay(physical) == root {
            return physical
        }
        return displays.first { $0.id == root && !$0.isVirtual }?.id ??
            displays.first { !$0.isVirtual && $0.mirrorMasterID == root }?.id ??
            displays.first { $0.id == desktop }?.id
    }

    private func adjustSingleDisplay(
        _ displayID: CGDirectDisplayID,
        delta: Double,
        showOSD: Bool,
        osdTitleOverride: String?
    ) {
        guard let idx = displays.firstIndex(where: { $0.id == displayID }) else { return }

        if displays[idx].activeBackend == .native {
            let elapsed = lastNativeWriteTime[displayID]?.duration(to: .now) ?? .seconds(10)
            if elapsed > .milliseconds(800) && smoothTargetValue[displayID] == nil {
                var currentNative: Float = Float(displays[idx].brightness)
                if LDDisplayServicesGetBrightness(displayID, &currentNative) {
                    displays[idx].brightness = Double(currentNative)
                    smoothRenderedValue[displayID] = Double(currentNative)
                }
            }
        }

        let nextVal = min(max(displays[idx].brightness + delta, 0.0), 1.0)
        setBrightness(nextVal, for: displayID, showOSD: showOSD, smooth: true, osdTitleOverride: osdTitleOverride)
    }

    // MARK: - Resolution & HiDPI (with 15s External Revert Safeguard)

    func applyDisplayMode(_ mode: DisplayModeItem, for display: DisplayItem) {
        let displayID = display.id
        guard !isShuttingDown, !topologyChanging, pendingModeRevert == nil,
              !mirrorState(for: displayID).isConnecting,
              DisplayTopology.uuid(displayID) == display.uuidString,
              let previous = CGDisplayCopyDisplayMode(displayID),
              previous.ioDisplayModeID != mode.cgMode.ioDisplayModeID else { return }

        let scope: CGConfigureOption = display.isBuiltIn ? .permanently : .forAppOnly
        guard DisplayModeManager.applyMode(mode.cgMode, to: displayID, scope: scope) else {
            setInlineError("해상도를 변경하지 못했습니다.", for: displayID)
            return
        }
        if !display.isBuiltIn {
            let preview = PendingModeRevert(displayUUID: display.uuidString, previewMode: mode.cgMode,
                deadline: .now.advanced(by: .seconds(15)), displayID: displayID,
                displayName: display.name, previousMode: previous, secondsRemaining: 15)
            pendingModeRevert = preview
            let token = preview.token
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tickPreview(token) }
            }
            RunLoop.main.add(timer, forMode: .common)
            revertTimer = timer
        }
        if !reconfigRegistered { refreshDisplays() }
    }

    private func tickPreview(_ token: UUID) {
        guard var preview = pendingModeRevert, preview.token == token else { return }
        let remaining = ContinuousClock.now.duration(to: preview.deadline)
        if remaining <= .zero {
            revertPendingMode()
        } else {
            let parts = remaining.components
            preview.secondsRemaining = Int(parts.seconds) + (parts.attoseconds > 0 ? 1 : 0)
            pendingModeRevert = preview
        }
    }

    private func endPreview() {
        revertTimer?.invalidate()
        revertTimer = nil
        pendingModeRevert = nil
    }

    /// Never restore onto a reused display ID or overwrite a subsequent change made in System Settings.
    private func currentPreview() -> PendingModeRevert? {
        guard let preview = pendingModeRevert else { return nil }
        let id = preview.displayID
        if CGDisplayIsOnline(id) != 0 {
            guard let uuid = DisplayTopology.uuid(id), let current = CGDisplayCopyDisplayMode(id) else {
                // A wake or a reconfiguration can temporarily hide the mode. Keep the recovery record.
                if ContinuousClock.now >= preview.deadline && preview.secondsRemaining != 0 {
                    pendingModeRevert?.secondsRemaining = 0
                }
                return nil
            }
            if uuid == preview.displayUUID && current.ioDisplayModeID == preview.previewMode.ioDisplayModeID {
                return preview
            }
        }
        endPreview()
        showBanner(.info, "화면 연결 또는 모드가 변경되어 해상도 확인을 종료했습니다.")
        return nil
    }

    func keepPendingMode() {
        guard let preview = currentPreview() else { return }
        if ContinuousClock.now >= preview.deadline {
            revertPendingMode()
            return
        }
        guard DisplayModeManager.applyMode(preview.previewMode, to: preview.displayID, scope: .permanently) else {
            showBanner(.error, "선택한 해상도를 저장하지 못했습니다.")
            return
        }
        endPreview()
    }

    func revertPendingMode() {
        guard var preview = currentPreview() else { return }
        guard DisplayModeManager.applyMode(preview.previousMode, to: preview.displayID, scope: .forAppOnly) else {
            revertTimer?.invalidate()
            revertTimer = nil
            preview.secondsRemaining = 0
            pendingModeRevert = preview
            showBanner(.error, "이전 해상도를 복구하지 못했습니다. 되돌리기를 다시 시도하세요.")
            return
        }
        endPreview()
        showBanner(.info, "\(preview.displayName) 해상도를 이전 설정으로 되돌렸습니다.")
        refreshDisplays()
    }

    // MARK: - Virtual HiDPI Mirroring

    func mirrorState(for displayID: CGDirectDisplayID) -> VirtualMirrorState {
        if let state = mirrorStates[displayID] { return state }
        if let record = virtualDisplayManager.mirrorRecord(forPhysicalDisplayID: displayID) {
            return virtualDisplayManager.isPending(record.id) ? .connecting : .active
        }
        return .idle
    }

    func toggleVirtualHiDPIMirror(for display: DisplayItem) {
        guard !isShuttingDown, DisplayTopology.uuid(display.id) == display.uuidString else { return }

        if let record = virtualDisplayManager.mirrorRecord(forPhysicalDisplayID: display.id) {
            let connecting = virtualDisplayManager.isPending(record.id)
            guard connecting || (!topologyChanging && pendingModeRevert == nil) else { return }
            guard virtualDisplayManager.removeVirtualDisplay(id: record.id) else {
                mirrorStates[display.id] = .failed("기존 미러 구성을 복원하지 못했습니다. 다시 시도해 주세요.")
                setInlineError("기존 미러 구성을 복원하지 못했습니다.", for: display.id)
                return
            }
            mirrorStates[display.id] = .idle
            setInlineError(nil, for: display.id)
            showBanner(.success, connecting ? "가상 HiDPI 연결을 취소했습니다." : "\(display.name) 가상 HiDPI 미러링을 해제했습니다.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.refreshDisplays()
            }
        } else {
            guard !topologyChanging, pendingModeRevert == nil else { return }
            guard virtualDisplayManager.isSupported else {
                mirrorStates[display.id] = .failed("이 macOS 버전에서는 가상 HiDPI를 지원하지 않습니다.")
                setInlineError("이 macOS 버전에서는 가상 HiDPI를 지원하지 않습니다.", for: display.id)
                return
            }
            mirrorStates[display.id] = .connecting
            setInlineError(nil, for: display.id)
            virtualDisplayManager.enableHiDPIMirror(for: display) { [weak self] ok, reason in
                guard let self, !self.isShuttingDown, DisplayTopology.uuid(display.id) == display.uuidString else { return }
                if ok {
                    self.mirrorStates[display.id] = .active
                    self.showBanner(.success, "\(display.name) 가상 HiDPI 미러링이 켜졌습니다.")
                } else {
                    let msg = reason ?? "가상 HiDPI 미러링을 시작하지 못했습니다."
                    self.mirrorStates[display.id] = .failed(msg)
                    self.setInlineError(msg, for: display.id)
                }
                self.refreshDisplays()
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
            showBanner(.success, "\(name) (\(preset.rawValue)) 가상 화면을 추가했습니다.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.refreshDisplays()
            }
        } else {
            showBanner(.error, "가상 디스플레이를 생성하지 못했습니다.")
        }
    }

    func removeVirtualDisplay(id: UUID) {
        guard virtualDisplayManager.removeVirtualDisplay(id: id) else {
            showBanner(.error, "미러 관계 복원에 실패해 가상 화면을 유지합니다.")
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
        guard baseW > 0, baseH > 0 else {
            setInlineError("현재 화면 해상도 정보를 확인할 수 없습니다.", for: display.id)
            return
        }
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
            setInlineError("해상도 설정 파일 생성에 실패했습니다.", for: display.id)
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
            showBanner(.success, "데스크톱에 해상도 설정 파일(\(baseW)×\(baseH) 기준)을 저장했습니다.")
        } catch {
            setInlineError("파일 저장 실패: \(error.localizedDescription)", for: display.id)
        }
    }

    // MARK: - Display Reconfiguration Callback

    private func registerDisplayReconfigurationCallback() {
        guard !reconfigRegistered else { return }
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        reconfigRegistered = CGDisplayRegisterReconfigurationCallback(displayChanged, pointer) == .success
        if !reconfigRegistered { showBanner(.warning, "화면 연결 변경 감지를 등록하지 못했습니다.") }
    }

    fileprivate func configurationChanged(beginning: Bool) {
        guard !isShuttingDown else { return }
        clearIdentify()
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
        DispatchQueue.main.asyncAfter(deadline: .now() + (beginning ? 1.0 : 0.35), execute: item)
    }

    // MARK: - Shutdown Cleanup

    func cleanupOnTerminate() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        revertPendingMode()
        endPreview()
        bannerDismissItem?.cancel()
        identifyWorkItem?.cancel()
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

    // MARK: - Banner & Inline Errors

    func dismissStatusBanner() {
        bannerDismissItem?.cancel()
        bannerDismissItem = nil
        statusBanner = nil
    }

    private func showBanner(_ level: StatusBanner.Level, _ message: String) {
        bannerDismissItem?.cancel()
        let autoDismiss = (level == .info || level == .success)
        let banner = StatusBanner(level: level, message: message, autoDismiss: autoDismiss)
        statusBanner = banner
        if autoDismiss {
            let work = DispatchWorkItem { [weak self] in
                if self?.statusBanner?.id == banner.id {
                    self?.statusBanner = nil
                }
            }
            bannerDismissItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
        }
    }

    private func setInlineError(_ message: String?, for displayID: CGDirectDisplayID) {
        if let i = displays.firstIndex(where: { $0.id == displayID }) {
            displays[i].inlineError = message
        }
    }

    // MARK: - Persistence Helpers

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
}
