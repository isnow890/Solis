import Foundation
import AppKit
import SwiftUI
import CoreGraphics

@MainActor
private final class BrightnessOSDModel: ObservableObject {
    enum Mode {
        case brightness
        case identify
    }

    @Published var mode: Mode = .brightness
    @Published var displayName: String = ""
    @Published var warningBadge: String?
    @Published var targetBrightness: Double = 1.0
    @Published var displayedBrightness: Double = 1.0
}

private struct BrightnessOSDView: View {
    @ObservedObject var model: BrightnessOSDModel

    private let segmentCount = 16

    var body: some View {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency

        VStack(spacing: 11) {
            Text(model.displayName)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            if model.mode == .identify {
                Image(systemName: "display")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.primary.opacity(0.92))
                    .frame(width: 44, height: 44)

                Text("현재 선택된 화면")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: brightnessIcon)
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(model.warningBadge == nil ? Color.primary.opacity(0.92) : Color.orange)
                    .frame(width: 44, height: 44)

                // Single-pass GPU Canvas bar with destinationOut notches (crisp in both Light & Dark mode)
                Canvas { context, size in
                    let fullRect = CGRect(origin: .zero, size: size)
                    let pill = Path(roundedRect: fullRect, cornerRadius: size.height / 2.0)

                    context.drawLayer { layer in
                        layer.clip(to: pill)
                        layer.fill(pill, with: .color(.primary.opacity(0.18)))

                        let fillW = size.width * CGFloat(min(max(model.displayedBrightness, 0.0), 1.0))
                        if fillW > 0.5 {
                            let fillRect = CGRect(x: 0, y: 0, width: fillW, height: size.height)
                            layer.fill(Path(fillRect), with: .color(.primary.opacity(0.92)))
                        }

                        // Punch clean transparent gaps so notches read sharply over any fill or wallpaper
                        layer.blendMode = .destinationOut
                        let step = size.width / CGFloat(segmentCount)
                        for idx in 1..<segmentCount {
                            let x = step * CGFloat(idx)
                            let tickRect = CGRect(x: x - 0.75, y: 0, width: 1.5, height: size.height)
                            layer.fill(Path(tickRect), with: .color(.black))
                        }
                    }
                }
                .frame(width: 178, height: 8)

                if let warning = model.warningBadge {
                    Text(warning)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.20), in: Capsule())
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else {
                    Text("\(Int((model.targetBrightness * 100).rounded()))%")
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(width: 214)
        .background {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(.primary.opacity(0.20), lineWidth: 0.75)
                    )
                    .shadow(color: .black.opacity(0.22), radius: 14, x: 0, y: 6)
            } else {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(.primary.opacity(0.14), lineWidth: 0.75)
                    )
                    .shadow(color: .black.opacity(0.20), radius: 14, x: 0, y: 6)
            }
        }
        .padding(24)
        .background(Color.clear)
    }

    private var brightnessIcon: String {
        if model.targetBrightness <= 0.05 {
            return "sun.min"
        } else if model.targetBrightness < 0.5 {
            return "sun.min.fill"
        } else {
            return "sun.max.fill"
        }
    }
}

/// Shows a native-looking translucent macOS HUD on the exact display whose brightness changed
/// (or identifies a monitor on card hover), with flicker-free 120Hz bar smoothing.
@MainActor
final class BrightnessOSDController {
    private let model = BrightnessOSDModel()
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?
    private var lastDisplayID: CGDirectDisplayID?

    private var barTimer: Timer?
    private var lastBarTick: CFTimeInterval = 0
    private var generation = 0
    private var isFadingOut: Bool = false

    private let panelSize = NSSize(width: 262, height: 204)

    func show(
        displayID: CGDirectDisplayID,
        displayName: String,
        warningBadge: String? = nil,
        brightness: Double
    ) {
        let clamped = min(max(brightness, 0.0), 1.0)
        guard let screen = DisplayTopology.screen(for: displayID) else { return }
        generation += 1
        let currentGeneration = generation

        let switchedDisplay = (lastDisplayID != displayID) || (panel?.isVisible != true) || (model.mode != .brightness)
        model.mode = .brightness
        model.displayName = displayName
        model.warningBadge = warningBadge
        model.targetBrightness = clamped

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if switchedDisplay || reduceMotion {
            model.displayedBrightness = clamped
            stopBarTimer()
        } else {
            startBarTimerIfNeeded()
        }

        presentPanel(on: screen, displayID: displayID, generation: currentGeneration, duration: warningBadge == nil ? 1.05 : 1.8)
        announceForVoiceOver("\(displayName) 밝기 \(Int((clamped * 100).rounded()))퍼센트" + (warningBadge.map { ", \($0)" } ?? ""))
    }

    func showIdentify(displayID: CGDirectDisplayID, displayName: String) {
        guard model.mode != .brightness || panel?.isVisible != true else { return }
        guard let screen = DisplayTopology.screen(for: displayID) else { return }
        generation += 1
        let currentGeneration = generation

        stopBarTimer()
        model.mode = .identify
        model.displayName = displayName
        model.warningBadge = nil

        presentPanel(on: screen, displayID: displayID, generation: currentGeneration, duration: 0.9)
    }

    func hideIfIdentify() {
        guard model.mode == .identify, let panel, panel.isVisible else { return }
        generation += 1
        hideWorkItem?.cancel()
        panel.orderOut(nil)
        isFadingOut = false
    }

    private func presentPanel(on screen: NSScreen, displayID: CGDirectDisplayID, generation currentGeneration: Int, duration: TimeInterval) {
        let origin = NSPoint(
            x: screen.frame.midX - panelSize.width / 2.0,
            y: screen.frame.minY + min(124.0, screen.frame.height * 0.14)
        )
        let targetFrame = NSRect(origin: origin, size: panelSize)

        if panel == nil {
            let newPanel = NSPanel(
                contentRect: targetFrame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            newPanel.isOpaque = false
            newPanel.backgroundColor = .clear
            newPanel.hasShadow = false
            newPanel.ignoresMouseEvents = true
            newPanel.hidesOnDeactivate = false
            newPanel.canHide = false
            newPanel.isReleasedWhenClosed = false
            newPanel.alphaValue = 0.0
            newPanel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 10)
            newPanel.collectionBehavior = [
                .canJoinAllSpaces,
                .fullScreenAuxiliary,
                .stationary,
                .ignoresCycle
            ]

            let host = NSHostingView(rootView: BrightnessOSDView(model: model))
            host.frame = NSRect(origin: .zero, size: panelSize)
            host.autoresizingMask = [.width, .height]
            host.wantsLayer = true
            host.layer?.backgroundColor = NSColor.clear.cgColor

            newPanel.contentView = host
            self.panel = newPanel
        } else if lastDisplayID != displayID || panel?.frame != targetFrame {
            panel?.setFrame(targetFrame, display: false)
        }
        lastDisplayID = displayID

        hideWorkItem?.cancel()

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let panel {
            if !panel.isVisible {
                isFadingOut = false
                if reduceMotion {
                    panel.alphaValue = 1.0
                    panel.orderFrontRegardless()
                } else {
                    panel.alphaValue = 0.0
                    panel.orderFrontRegardless()
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.12
                        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        panel.animator().alphaValue = 1.0
                    }
                }
            } else if isFadingOut || panel.alphaValue < 0.99 {
                isFadingOut = false
                if reduceMotion {
                    panel.alphaValue = 1.0
                } else {
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.08
                        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        panel.animator().alphaValue = 1.0
                    }
                }
            }
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.generation == currentGeneration, let panel = self.panel else { return }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                panel.orderOut(nil)
                self.isFadingOut = false
                self.stopBarTimer()
                return
            }
            self.isFadingOut = true
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.26
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().alphaValue = 0.0
            }, completionHandler: { [weak self, weak panel] in
                Task { @MainActor in
                    if self?.generation == currentGeneration, let panel, panel.alphaValue <= 0.02 {
                        panel.orderOut(nil)
                        self?.isFadingOut = false
                        self?.stopBarTimer()
                    }
                }
            })
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }

    private func announceForVoiceOver(_ message: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }

    func close() {
        generation += 1
        hideWorkItem?.cancel()
        stopBarTimer()
        panel?.close()
        panel = nil
        lastDisplayID = nil
    }

    private func startBarTimerIfNeeded() {
        guard barTimer == nil else { return }
        lastBarTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stepBarAnimation()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        barTimer = timer
    }

    private func stopBarTimer() {
        barTimer?.invalidate()
        barTimer = nil
    }

    private func stepBarAnimation() {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastBarTick, 1.0 / 240.0), 0.05)
        lastBarTick = now

        let diff = model.targetBrightness - model.displayedBrightness
        if abs(diff) < 0.001 {
            model.displayedBrightness = model.targetBrightness
            stopBarTimer()
        } else {
            let blend = 1.0 - exp(-dt * 24.0)
            model.displayedBrightness += diff * blend
        }
    }
}
