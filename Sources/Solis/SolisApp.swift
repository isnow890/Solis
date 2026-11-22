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
        // Pure menu bar app: stay in top status bar, never appear in Dock, never restore stray windows
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
        // Re-opening the app bundle opens the menu bar popover instead of spawning a blank window
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
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.mobb.Solis")
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

    // MARK: - Menu Bar Status Item & Popover

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = makeSolisMenuBarIcon()
            button.toolTip = "Solis — 화면별 밝기 & HiDPI"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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
            let planetRadius: CGFloat = 4.25

            // Primary hero Saturn ring (-16°), wide & bold
            let mainRX: CGFloat = 8.8
            let mainRY: CGFloat = 2.4
            let mainTilt: CGFloat = -16.0 * .pi / 180.0

            // Secondary low-angle accent orbit (+28°), tighter & thinner
            let subRX: CGFloat = 7.4
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

            // 1) Draw full asymmetric rings behind planet
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineCap(.round)
            ctx.setLineWidth(0.95)
            ctx.addPath(ellipsePath(rx: subRX, ry: subRY, angle: subTilt, frontOnly: false))
            ctx.strokePath()

            ctx.setLineWidth(1.4)
            ctx.addPath(ellipsePath(rx: mainRX, ry: mainRY, angle: mainTilt, frontOnly: false))
            ctx.strokePath()

            // 2) Draw solid center planet sphere
            let planetRect = CGRect(
                x: center.x - planetRadius,
                y: center.y - planetRadius,
                width: planetRadius * 2,
                height: planetRadius * 2
            )
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillEllipse(in: planetRect)

            // 3) Punch clean negative-space gap where the primary hero ring crosses in front of the planet
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            ctx.setLineCap(.round)
            ctx.setLineWidth(2.9)
            ctx.addPath(ellipsePath(rx: mainRX, ry: mainRY, angle: mainTilt, frontOnly: true))
            ctx.strokePath()
            ctx.restoreGState()

            // 4) Draw crisp front arc of primary hero ring
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineCap(.round)
            ctx.setLineWidth(1.4)
            ctx.addPath(ellipsePath(rx: mainRX, ry: mainRY, angle: mainTilt, frontOnly: true))
            ctx.strokePath()

            // 5) Tiny moon dot on upper-right of the secondary ring
            let moonAngle: CGFloat = 0.28
            let mxLocal = cos(moonAngle) * subRX
            let myLocal = sin(moonAngle) * subRY
            let mx = center.x + mxLocal * cos(subTilt) - myLocal * sin(subTilt)
            let my = center.y + mxLocal * sin(subTilt) + myLocal * cos(subTilt)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillEllipse(in: CGRect(x: mx - 1.15, y: my - 1.15, width: 2.3, height: 2.3))

            return true
        }
        image.isTemplate = true
        return image
    }

    private func setupPopover(controller: DisplayController) {
        let popover = NSPopover()
        popover.behavior = .transient
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

        if event.type == .rightMouseUp {
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
                controller?.popoverAvailableHeight = max(1, screen.visibleFrame.height - 20)
            }
            controller?.refreshAccessibilityStatus()
            controller?.refreshDisplays()
            controller?.startCursorTracking()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
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

    private func showContextMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "디스플레이 새로고침", action: #selector(refreshFromMenu), keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Solis 종료", action: #selector(quitFromMenu), keyEquivalent: "q")

        for item in menu.items {
            item.target = self
        }

        statusItem?.menu = menu
        button.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func refreshFromMenu() {
        controller?.refreshDisplays()
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }
}
