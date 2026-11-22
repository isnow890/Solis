import SwiftUI
import AppKit
import CoreGraphics
import CDisplayBridge

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var controller: DisplayController?
    private var eventMonitor: Any?
    private var predecessorExit: DispatchSourceProcess?

    static func main() {
        if CommandLine.arguments.contains("--diagnose") {
            runDiagnosticsAndExit()
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // A replacement must start applying display state only after its predecessor has restored its LUTs.
        let arguments = CommandLine.arguments
        if let option = arguments.firstIndex(of: "--replacing-pid"), option + 1 < arguments.count,
           let pid = pid_t(arguments[option + 1]), pid != getpid(),
           let old = NSRunningApplication(processIdentifier: pid), old.bundleURL == Bundle.main.bundleURL {
            let monitor = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            predecessorExit = monitor
            monitor.setEventHandler { [weak self] in self?.startMenuBar() }
            monitor.resume()
            if old.isTerminated { startMenuBar() }
        } else {
            startMenuBar()
        }
    }

    private func startMenuBar() {
        guard controller == nil else { return }
        predecessorExit?.cancel()
        predecessorExit = nil
        let controller = DisplayController()
        self.controller = controller

        setupStatusItem()
        setupPopover(controller: controller)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        controller?.refreshAccessibilityStatus()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        controller?.cleanupOnTerminate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let button = statusItem?.button {
            togglePopover(button)
        }
        return false
    }

    // MARK: - Diagnostics CLI Mode

    private static func runDiagnosticsAndExit() {
        print("=== Solis Diagnostics ===")
        print("DisplayServices available: \(LDDisplayServicesIsAvailable())")
        print("IOAVService available:     \(LDIOAVServiceIsAvailable())")
        print("CGVirtualDisplay support:  \(LDVirtualDisplayHandle.isSupported())")
        let access = BrightnessKeyMonitor.Status()
        print("CLI preflight: AX=\(access.accessibility) PostEvent=\(access.postEvent)")
        print("Standard F1/F2 capture: \(BrightnessKeyMonitor.standardKeysDefault)")
        print("Ctrl+Option+Arrow capture: \(BrightnessKeyMonitor.ctrlOptionArrowsDefault)")
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.isnow890.solis")
            .filter { $0.processIdentifier != getpid() }
        if apps.isEmpty { print("GUI event tap: no running app") }
        for app in apps {
            if let tap = BrightnessKeyMonitor.tapInfo(pid: app.processIdentifier) {
                print("GUI pid=\(app.processIdentifier) enabled=\(tap.enabled) actualMask=0x\(String(tap.eventsOfInterest, radix: 16)) requiredByThisBuild=0x\(String(BrightnessKeyMonitor.requiredMask, radix: 16))")
            } else { print("GUI pid=\(app.processIdentifier) has no matching tap") }
        }
        guard let ids = DisplayTopology.onlineIDs() else {
            print("CGGetOnlineDisplayList failed")
            exit(1)
        }
        let ports = LDMatchedDDCPorts(ids.map { NSNumber(value: $0) })

        let screenByID = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { s -> (CGDirectDisplayID, NSScreen)? in
            guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            return (id, s)
        })

        for id in ids {
            let name = screenByID[id]?.localizedName ?? "Display \(id)"
            let vendor = CGDisplayVendorNumber(id)
            let product = CGDisplayModelNumber(id)
            let serial = CGDisplaySerialNumber(id)
            let builtIn = CGDisplayIsBuiltin(id) != 0
            let canNative = LDDisplayServicesCanChangeBrightness(id)
            var nativeVal: Float = -1
            let gotNative = canNative ? LDDisplayServicesGetBrightness(id, &nativeVal) : false

            var ddcStatus = "skipped(built-in)"
            if !builtIn {
                if let port = ports[NSNumber(value: id)], let av = LDCreateAVServiceForPort(port) {
                    var profile: UInt8 = 0
                    let reading = DDCReading(service: av, profile: &profile)
                    ddcStatus = "\(port) · \(reading.description) · 쓰기 미검사"
                } else {
                    ddcStatus = "고유 AVService 없음"
                }
            }

            let modeBundle = DisplayModeManager.listModes(for: id)
            let hiDPICount = modeBundle.modes.filter { $0.isHiDPI }.count
            print("- [\(id)] \(name) | vendor=\(vendor) product=\(product) serial=\(serial) builtIn=\(builtIn)")
            print("    Native: can=\(canNative) read=\(gotNative ? String(format: "%.2f", nativeVal) : "n/a")")
            print("    DDC/CI: \(ddcStatus)")
            print("    Modes:  unique=\(modeBundle.modes.count), HiDPI=\(hiDPICount), refreshOptions=\(modeBundle.currentRefreshModes.map(\.refreshLabel))")
        }

        exit(0)
    }

    // MARK: - Menu Bar Status Item & Popover (P1-13, P2)

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = makeSolisMenuBarIcon()
            button.toolTip = "Solis — 화면별 밝기 & HiDPI"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            // Open immediately on mouseDown like native macOS menu bar items
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        self.statusItem = item
    }

    /// Custom monochrome template icon matching the asymmetric dual-ringed Saturn Solis app icon.
    private func makeSolisMenuBarIcon() -> NSImage {
        let size = NSSize(width: 20, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldAntialias(true)

            let center = CGPoint(x: rect.midX, y: rect.midY)
            // Slightly lighter planet radius & crisp ring thickness for clean legibility next to macOS SF Symbols
            let planetRadius: CGFloat = 3.85

            let mainRX: CGFloat = 8.6
            let mainRY: CGFloat = 2.45
            let mainTilt: CGFloat = -16.0 * .pi / 180.0

            let subRX: CGFloat = 7.1
            let subRY: CGFloat = 1.95
            let subTilt: CGFloat = 28.0 * .pi / 180.0

            func ellipsePath(rx: CGFloat, ry: CGFloat, angle: CGFloat, frontOnly: Bool) -> CGPath {
                let path = CGMutablePath()
                let start: CGFloat = frontOnly ? .pi : 0.0
                let end: CGFloat = 2.0 * .pi
                let steps = frontOnly ? 48 : 96
                for i in 0...steps {
                    let t = start + (end - start) * CGFloat(i) / CGFloat(steps)
                    let x = cos(t) * rx
                    let y = sin(t) * ry
                    let rxp = center.x + x * cos(angle) - y * sin(angle)
                    let ryp = center.y + x * sin(angle) + y * cos(angle)
                    if i == 0 {
                        path.move(to: CGPoint(x: rxp, y: ryp))
                    } else {
                        path.addLine(to: CGPoint(x: rxp, y: ryp))
                    }
                }
                return path
            }

            // 1) Draw asymmetric rings behind planet
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineCap(.round)
            ctx.setLineWidth(1.0)
            ctx.addPath(ellipsePath(rx: subRX, ry: subRY, angle: subTilt, frontOnly: false))
            ctx.strokePath()

            ctx.setLineWidth(1.45)
            ctx.addPath(ellipsePath(rx: mainRX, ry: mainRY, angle: mainTilt, frontOnly: false))
            ctx.strokePath()

            // 2) Draw center planet sphere
            let planetRect = CGRect(
                x: center.x - planetRadius,
                y: center.y - planetRadius,
                width: planetRadius * 2,
                height: planetRadius * 2
            )
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillEllipse(in: planetRect)

            // 3) Punch crisp negative-space cutout along front arc
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            ctx.setLineCap(.round)
            ctx.setLineWidth(3.0)
            ctx.addPath(ellipsePath(rx: mainRX, ry: mainRY, angle: mainTilt, frontOnly: true))
            ctx.strokePath()
            ctx.restoreGState()

            // 4) Redraw front arc of hero ring
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineCap(.round)
            ctx.setLineWidth(1.45)
            ctx.addPath(ellipsePath(rx: mainRX, ry: mainRY, angle: mainTilt, frontOnly: true))
            ctx.strokePath()

            // 5) Tiny moon accent at upper-right
            let moonAngle: CGFloat = 0.26
            let mxLocal = cos(moonAngle) * subRX
            let myLocal = sin(moonAngle) * subRY
            let mx = center.x + mxLocal * cos(subTilt) - myLocal * sin(subTilt)
            let my = center.y + mxLocal * sin(subTilt) + myLocal * cos(subTilt)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillEllipse(in: CGRect(x: mx - 1.1, y: my - 1.1, width: 2.2, height: 2.2))

            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Solis 디스플레이 제어"
        return image
    }

    private func setupPopover(controller: DisplayController) {
        let popover = NSPopover()
        // Use applicationDefined + our own outside-click monitor so clicking the status button cleanly toggles without close+reopen.
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self

        let hosting = NSHostingController(
            rootView: MenuBarPopoverView(controller: controller)
        )
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        self.popover = popover
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            togglePopover(sender)
            return
        }

        let isRightOrCtrlClick = (event.type == .rightMouseDown || event.type == .rightMouseUp) ||
            event.modifierFlags.contains(.control)

        if isRightOrCtrlClick {
            closePopover()
            showContextMenu(from: sender)
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        guard let popover else { return }
        if popover.isShown {
            closePopover()
        } else {
            if let screen = sender.window?.screen {
                controller?.popoverAvailableHeight = max(280, screen.visibleFrame.height - 24)
            }
            controller?.refreshAccessibilityStatus()
            controller?.refreshDisplays()
            controller?.startCursorTracking()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            // Keep popover readable even when software overlay dims the screen toward 0% (P2)
            if let popWindow = popover.contentViewController?.view.window {
                popWindow.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 2)
            }
            installOutsideClickMonitor()
        }
    }

    private func closePopover() {
        popover?.performClose(nil)
        controller?.stopCursorTracking()
        removeOutsideClickMonitor()
    }

    func popoverDidClose(_ notification: Notification) {
        controller?.stopCursorTracking()
        removeOutsideClickMonitor()
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                if self?.popover?.isShown == true {
                    self?.closePopover()
                }
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    // MARK: - Rich Right-Click Context Menu (P1-13)

    private func showContextMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()

        let header = NSMenuItem(title: "키보드 밝기 대상", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        for mode in BrightnessKeyTargetMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectTargetModeFromMenu(_:)), keyEquivalent: "")
            item.representedObject = mode.rawValue
            item.state = (controller?.keyTargetMode == mode) ? .on : .off
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "설정…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let loginItem = NSMenuItem(title: "로그인 시 자동 실행", action: #selector(toggleLoginFromMenu), keyEquivalent: "")
        loginItem.state = (controller?.launchAtLogin == true) ? .on : .off
        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let versionItem = NSMenuItem(title: "Solis \(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        let quitItem = NSMenuItem(title: "Solis 종료", action: #selector(quitFromMenu), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        button.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func selectTargetModeFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = BrightnessKeyTargetMode(rawValue: raw) else { return }
        controller?.keyTargetMode = mode
    }

    @objc private func openSettingsFromMenu() {
        controller?.showSettingsInPopover = true
        if let button = statusItem?.button, popover?.isShown != true {
            togglePopover(button)
        }
    }

    @objc private func toggleLoginFromMenu() {
        let next = !(controller?.launchAtLogin ?? false)
        controller?.setLaunchAtLogin(next)
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }
}
