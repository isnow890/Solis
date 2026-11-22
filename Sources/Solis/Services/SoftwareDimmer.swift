import Foundation
import AppKit
import CoreGraphics

/// Provides software brightness dimming via either:
/// 1) Click-through black overlay panels (works universally on DisplayLink, HDMI, HDR, rotated screens)
/// 2) CoreGraphics gamma transfer formula (dims cursor & native pipeline on supported displays)
@MainActor
final class SoftwareDimmer {
    private var overlayWindows: [CGDirectDisplayID: NSPanel] = [:]
    private var overlayLevels: [CGDirectDisplayID: Double] = [:]
    private struct GammaTable: Equatable {
        var red: [CGGammaValue]
        var green: [CGGammaValue]
        var blue: [CGGammaValue]

        static func read(_ id: CGDirectDisplayID) -> Self? {
            let capacity = CGDisplayGammaTableCapacity(id)
            guard capacity > 0, capacity <= 65536 else { return nil }
            var red = [CGGammaValue](repeating: 0, count: Int(capacity))
            var green = red, blue = red
            var count: UInt32 = 0
            guard CGGetDisplayTransferByTable(id, capacity, &red, &green, &blue, &count) == .success,
                  count > 0, count <= capacity else { return nil }
            return Self(red: Array(red.prefix(Int(count))), green: Array(green.prefix(Int(count))),
                        blue: Array(blue.prefix(Int(count))))
        }

        func scaled(_ factor: Float) -> Self {
            Self(red: red.map { $0 * factor }, green: green.map { $0 * factor }, blue: blue.map { $0 * factor })
        }

        func write(_ id: CGDirectDisplayID) -> Bool {
            CGSetDisplayTransferByTable(id, UInt32(red.count), red, green, blue) == .success
        }
    }

    private var gamma: [String: (original: GammaTable, applied: GammaTable)] = [:]

    /// Maximum black overlay opacity when brightness == 0.0 (keeps screen barely readable instead of pitch-black lockout)
    private let maxOverlayOpacity: CGFloat = 0.85

    // MARK: - Overlay Dimming

    func setOverlayBrightness(_ brightness: Double, for displayID: CGDirectDisplayID) {
        overlayLevels[displayID] = min(max(brightness, 0), 1)
        guard let screen = DisplayTopology.screen(for: displayID) else { return }
        renderOverlay(on: screen)
    }

    private func renderOverlay(on screen: NSScreen) {
        guard let displayID = DisplayTopology.screenID(screen) else { return }
        // Mirrored outputs share pixels. Apply the darkest requested level once on the shared desktop.
        let group = DisplayTopology.desktopID(displayID)
        let clamped = overlayLevels.filter { DisplayTopology.desktopID($0.key) == group }.values.min() ?? 1
        if clamped >= 0.996 {
            overlayWindows.removeValue(forKey: displayID)?.close()
            return
        }
        let panel: NSPanel
        if let existing = overlayWindows[displayID] {
            panel = existing
            if panel.frame != screen.frame {
                panel.setFrame(screen.frame, display: false)
            }
        } else {
            panel = createOverlayPanel(frame: screen.frame)
            panel.alphaValue = 0.0
            overlayWindows[displayID] = panel
        }

        // Gentle perceptual curve so dimming feels linear to human eyes
        let dimming = 1.0 - clamped
        let alpha = CGFloat(pow(dimming, 0.92)) * maxOverlayOpacity

        panel.alphaValue = alpha
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    func removeOverlay(for displayID: CGDirectDisplayID) {
        overlayLevels.removeValue(forKey: displayID)
        if let screen = DisplayTopology.screen(for: displayID) { renderOverlay(on: screen) }
    }

    func syncOverlayFrames(online: Set<CGDirectDisplayID>) {
        overlayLevels = overlayLevels.filter { online.contains($0.key) }
        let screens = NSScreen.screens
        let visible = Set(screens.compactMap(DisplayTopology.screenID))
        for id in Array(overlayWindows.keys) where !visible.contains(id) {
            overlayWindows.removeValue(forKey: id)?.close()
        }
        for screen in screens { renderOverlay(on: screen) }
    }

    private func createOverlayPanel(frame: NSRect) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) - 1)
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        return panel
    }

    // MARK: - Gamma Dimming

    @discardableResult
    func setGammaBrightness(_ brightness: Double, for displayID: CGDirectDisplayID) -> Bool {
        if brightness >= 0.995 { return resetGamma(for: displayID) }
        guard let uuid = DisplayTopology.uuid(displayID), let current = GammaTable.read(displayID) else { return false }
        if let saved = gamma[uuid], saved.applied != current {
            // Another color manager acquired the table. Leave its new profile in place.
            gamma.removeValue(forKey: uuid)
            return false
        }
        let original = gamma[uuid]?.original ?? current
        let target = original.scaled(Float(0.12 + max(0.05, brightness) * 0.88))
        guard target.write(displayID) else { return false }
        gamma[uuid] = (original, GammaTable.read(displayID) ?? target)
        return true
    }

    @discardableResult
    func resetGamma(for displayID: CGDirectDisplayID) -> Bool {
        guard let uuid = DisplayTopology.uuid(displayID), let saved = gamma[uuid] else { return true }
        guard let current = GammaTable.read(displayID) else { return false }
        if current == saved.applied && !saved.original.write(displayID) { return false }
        gamma.removeValue(forKey: uuid)
        return true
    }

    func resetAll() {
        for panel in overlayWindows.values { panel.close() }
        overlayWindows.removeAll()
        overlayLevels.removeAll()
        for id in DisplayTopology.onlineIDs() ?? [] where !resetGamma(for: id) {
            NSLog("Solis: 감마 복원 실패 (display %u)", id)
        }
    }
}
