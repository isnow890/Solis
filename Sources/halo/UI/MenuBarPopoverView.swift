import SwiftUI
import CoreGraphics
import AppKit

struct MenuBarPopoverView: View {
    @ObservedObject var controller: DisplayController
    @ObservedObject var updates: UpdateChecker

    @State private var expandedDisplayID: CGDirectDisplayID?
    @State private var showStandaloneVirtualSection: Bool = false
    @State private var selectedPreset: VirtualDisplayPreset = .uhd16x9
    @State private var contentHeight: CGFloat = 0
    @State private var confirmationHeight: CGFloat = 0

    var body: some View {
        // The confirmation normally sits inside the card whose resolution changed; this top banner is the
        // fallback for when that card's resolution list is not on screen (collapsed card or settings panel).
        let topRevert = controller.pendingModeRevert.flatMap { inlineRevertDisplayID(for: $0) == nil ? $0 : nil }
        let available = max(1, controller.popoverAvailableHeight - (topRevert == nil ? 0 : confirmationHeight))
        let needsScroll = contentHeight > available
        VStack(spacing: 0) {
            if let revert = topRevert {
                VStack(spacing: 0) {
                    modeRevertBanner(revert)
                    Divider()
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { confirmationHeight = $0 }
            }
            ScrollView(.vertical, showsIndicators: needsScroll) {
                popoverContents
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { geometry in
                        Color.clear.onAppear { contentHeight = geometry.size.height }
                            .onChange(of: geometry.size.height) { _, height in contentHeight = height }
                    })
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(available, contentHeight > 0 ? contentHeight : available))
        }
        .frame(width: 360)
    }

    private var popoverContents: some View {
        VStack(spacing: 0) {
            headerBar

            Divider()

            if let banner = controller.statusBanner {
                statusBannerView(banner)
                Divider()
            }

            if let release = updates.available {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L("halo \(release.version) 업데이트", "halo \(release.version) is available"))
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Link(L("릴리즈 열기", "Open Release"), destination: release.url)
                            .font(.caption.weight(.medium))
                    }
                    HStack(spacing: 6) {
                        Button(L("나중에", "Later"), action: updates.dismissForSession)
                        Button(L("이 버전 건너뛰기", "Skip This Version"), action: updates.skip)
                    }
                    .controlSize(.mini)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.10))
                Divider()
            }
            if let message = updates.manualMessage {
                HStack {
                    Text(message).font(.caption)
                    Spacer()
                    Button { updates.manualMessage = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L("업데이트 알림 닫기", "Dismiss update notice"))
                }
                .padding(10)
                Divider()
            }
            if !controller.isAccessibilityGranted && (!controller.permissionBannerDeferred || controller.needsPermissionRelaunch) {
                accessibilityCallout
                Divider()
            }

            if controller.showSettingsInPopover {
                settingsPanel
            } else {
                mainContent
            }
        }
        .frame(width: 360)
    }

    // MARK: - Header (P1-3, P2: Clean minimal header without clutter or accidental quit)

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text("halo")
                .font(.headline)

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    controller.showSettingsInPopover.toggle()
                }
            } label: {
                Image(systemName: controller.showSettingsInPopover ? "gearshape.fill" : "gearshape")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(controller.showSettingsInPopover ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .help(L("설정", "Settings"))
            .accessibilityLabel(L("설정", "Settings"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Mode Revert Safety Banner (P1-7)

    private func modeRevertBanner(_ revert: PendingModeRevert) -> some View {
        ModeRevertPrompt(revert: revert, title: L("\(revert.displayName) 해상도 변경됨", "\(revert.displayName) resolution changed"),
                         onRevert: controller.revertPendingMode, onKeep: controller.keepPendingMode)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.12))
    }

    /// The physical display card that currently shows the confirmation next to its resolution list, if any.
    private func inlineRevertDisplayID(for revert: PendingModeRevert) -> CGDirectDisplayID? {
        guard !controller.showSettingsInPopover, let expanded = expandedDisplayID,
              controller.visibleDisplays.contains(where: { $0.id == expanded }) else { return nil }
        let modeSourceID = controller.mirroredVirtualDisplay(for: expanded)?.id ?? expanded
        return modeSourceID == revert.displayID ? expanded : nil
    }

    // MARK: - Status Banner (P0-2)

    private func statusBannerView(_ banner: StatusBanner) -> some View {
        let iconName: String
        let tint: Color
        switch banner.level {
        case .info:
            iconName = "info.circle.fill"
            tint = .accentColor
        case .success:
            iconName = "checkmark.circle.fill"
            tint = .accentColor
        case .warning:
            iconName = "exclamationmark.triangle.fill"
            tint = .orange
        case .error:
            iconName = "xmark.octagon.fill"
            tint = .red
        }

        return HStack(alignment: .top, spacing: 7) {
            Image(systemName: iconName)
                .foregroundStyle(tint)
                .font(.caption)
                .padding(.top, 1)
            Text(banner.message)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if !banner.autoDismiss {
                Button {
                    controller.dismissStatusBanner()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L("알림 닫기", "Dismiss notice"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.11))
    }

    // MARK: - Accessibility Callout (P0-1, P0-7)

    private var accessibilityTitle: String {
        if controller.needsPermissionRelaunch {
            return L("키보드 밝기 키 연결 대기", "Waiting for brightness keys to connect")
        }
        if controller.needsAdditionalPermission {
            return L("키보드 이벤트 제어 권한 필요", "Keyboard event permission needed")
        }
        return controller.didRequestBrightnessPermission ? L("키보드 밝기 키 권한 확인 중", "Checking brightness key permission") : L("키보드 밝기 키 권한 필요", "Brightness key permission needed")
    }

    private var accessibilityHelp: String {
        if controller.needsPermissionRelaunch {
            return L("권한은 켜져 있지만 연결이 갱신되지 않았습니다. 앱을 재시작하거나, 설정에서 기존 halo를 (−)로 삭제 후 다시 허용해 주세요.", "Permission is on, but the connection has not refreshed. Restart the app, or remove halo with (−) in Settings and allow it again.")
        }
        if controller.needsAdditionalPermission {
            return L("손쉬운 사용은 허용되었지만 키보드 이벤트 제어 권한이 아직 필요합니다. 설정에서 halo의 권한을 확인해 주세요.", "Accessibility is allowed, but keyboard event permission is still needed. Check halo's permissions in Settings.")
        }
        if controller.didRequestBrightnessPermission {
            return L("설정에서 halo를 허용하세요. 이미 켜져 있다면 기존 halo를 −로 제거한 뒤 +로 현재 앱을 추가하고 다시 허용하세요.", "Allow halo in Settings. If it is already on, remove halo with −, add this app with +, and allow it again.")
        }
        return BrightnessKeyMonitor.permissionExplanation
    }

    private var permissionSettingsHint: String {
        if #available(macOS 27.3, *) {
            return L("개인정보 보호 및 보안에서 halo가 요청한 항목을 확인하세요.", "Check the item halo requested under Privacy & Security.")
        }
        if #available(macOS 27, *) { return L("개인정보 보호 및 보안 > 기기 제어 및 데이터 접근", "Privacy & Security > Device Control and Data Access") }
        return L("개인정보 보호 및 보안 > 손쉬운 사용", "Privacy & Security > Accessibility")
    }

    private var accessibilityCallout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(accessibilityTitle)
                        .font(.caption.weight(.semibold))
                    Text(accessibilityHelp)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(permissionSettingsHint)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 6) {
                if controller.needsPermissionRelaunch {
                    Button(L("앱 재시작", "Restart App"), action: controller.relaunchApp)
                        .buttonStyle(.borderedProminent)
                    Button(L("설정 열기", "Open Settings"), action: controller.requestAccessibilityPermission)
                } else if controller.needsAdditionalPermission || controller.didRequestBrightnessPermission {
                    Button(L("설정 열기", "Open Settings"), action: controller.requestAccessibilityPermission)
                        .buttonStyle(.borderedProminent)
                    Button(L("나중에", "Later")) { controller.permissionBannerDeferred = true }
                } else {
                    Button(L("권한 허용", "Allow"), action: controller.requestAccessibilityPermission)
                        .buttonStyle(.borderedProminent)
                    Button(L("나중에", "Later")) { controller.permissionBannerDeferred = true }
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.10))
    }

    // MARK: - Main Content

    private var mainContent: some View {
        VStack(spacing: 0) {
            keyTargetStrip
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

            VStack(spacing: 8) {
                ForEach(controller.visibleDisplays) { display in
                    let modeSource = controller.mirroredVirtualDisplay(for: display.id) ?? display
                    DisplayCardView(
                        display: display,
                        modeSourceDisplay: modeSource,
                        isKeyTarget: controller.isKeyTarget(display.id),
                        keyTargetMode: controller.keyTargetMode,
                        mirrorState: controller.mirrorState(for: display.id),
                        previewPending: controller.pendingModeRevert != nil,
                        pendingRevert: controller.pendingModeRevert.flatMap {
                            inlineRevertDisplayID(for: $0) == display.id ? $0 : nil
                        },
                        isExpanded: expandedDisplayID == display.id,
                        onHoverChange: { hovering in
                            if hovering {
                                controller.scheduleIdentifyDisplay(display)
                            } else {
                                controller.clearIdentify(for: display)
                            }
                        },
                        onToggleExpand: {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                expandedDisplayID = (expandedDisplayID == display.id) ? nil : display.id
                            }
                        },
                        onBrightnessChange: { newVal in
                            controller.setBrightness(newVal, for: display.id, showOSD: false)
                        },
                        onBackendSelect: { backend in
                            controller.switchBackend(backend, for: display.id)
                        },
                        onModeSelect: { mode in
                            controller.applyDisplayMode(mode, for: modeSource)
                        },
                        onToggleVirtualHiDPI: {
                            controller.toggleVirtualHiDPIMirror(for: display)
                        },
                        onExportOverride: {
                            controller.exportDisplayOverridePlist(for: display)
                        },
                        onRevertMode: controller.revertPendingMode,
                        onKeepMode: controller.keepPendingMode
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    // MARK: - Key Target Strip

    private var keyTargetStrip: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(L("키보드 밝기 대상", "Brightness key target"), systemImage: "keyboard")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(shortcutSummaryText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }

            Picker(L("키보드 밝기 대상", "Brightness key target"), selection: $controller.keyTargetMode) {
                ForEach(BrightnessKeyTargetMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!controller.isAccessibilityGranted)
            if !controller.isAccessibilityGranted {
                HStack {
                    Text(L("밝기 키 연결 후 대상을 선택할 수 있습니다.", "You can choose a target once the brightness keys are connected."))
                    Spacer()
                    if controller.permissionBannerDeferred {
                        Button(L("권한 안내", "Permission Help")) { controller.permissionBannerDeferred = false }
                            .buttonStyle(.link)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var shortcutSummaryText: String {
        let base = controller.captureStandardKeys ? "F1/F2" : L("밝기 키", "Brightness keys")
        return controller.captureCtrlOptionArrows ? "\(base) · ⌃⌥↑↓" : base
    }

    // MARK: - Settings Panel (P0-5, P0-6, P1-9, P2)

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("설정", "Settings"))
                .font(.callout.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: Binding(
                    get: { controller.launchAtLogin },
                    set: { controller.setLaunchAtLogin($0) }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("로그인 시 자동 실행", "Launch at Login"))
                            .font(.callout)
                        Text(L("macOS 시작 시 상단 메뉴바에 자동으로 실행합니다.", "Starts in the menu bar when you log in."))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                if controller.loginNeedsApproval {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        Text(L("승인 대기 · 로그인 항목에서 halo를 켜주세요", "Awaiting approval · turn on halo in Login Items"))
                            .font(.caption2)
                            .foregroundStyle(.primary)
                        Spacer()
                        Button(L("열기", "Open"), action: controller.openLoginSettings)
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                }
            }

            HStack(alignment: .center, spacing: 8) {
                Toggle(isOn: $updates.automaticallyChecks) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("업데이트 자동 확인", "Check for updates automatically"))
                            .font(.callout)
                        Text(L("하루 1회 GitHub에서 최신 버전 번호만 조회합니다.", "Looks up only the latest version number on GitHub once a day."))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                Spacer(minLength: 4)
                Button(updates.checking ? L("확인 중…", "Checking…") : L("지금 확인", "Check Now"), action: updates.checkManually)
                    .disabled(updates.checking)
            }
            .controlSize(.small)

            Toggle(isOn: $controller.captureStandardKeys) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("표준 F1 / F2로 밝기 조절", "Use standard F1 / F2 for brightness"))
                        .font(.callout)
                    Text(L("켜면 다른 앱의 F1/F2 단축키 대신 halo 밝기 조절이 동작합니다.", "When on, F1/F2 adjust brightness in halo instead of acting as shortcuts in other apps."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle(isOn: $controller.captureCtrlOptionArrows) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("⌃⌥↑ / ⌃⌥↓ 대체 단축키 사용", "Use ⌃⌥↑ / ⌃⌥↓ as alternate shortcuts"))
                        .font(.callout)
                    Text(L("밝기 키가 없는 외장 키보드용 옵션입니다 (기본 꺼짐).", "For external keyboards without brightness keys (off by default)."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle(isOn: $controller.cleanupVirtualOnQuit) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("종료 시 기존 미러 구성 복구", "Restore mirroring setup on quit"))
                        .font(.callout)
                    Text(L("가상 화면은 앱 종료 시 사라지며, 켜면 이전 미러 배치를 명시적으로 복원합니다.", "Virtual displays disappear when the app quits. When on, the previous mirroring layout is restored explicitly."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Divider()

            // Standalone Virtual Display moved into Advanced inside Settings (P0-5)
            DisclosureGroup(isExpanded: $showStandaloneVirtualSection) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(L("보이지 않는 확장 화면이 추가됩니다 (화면 녹화·스트리밍·테스트용).", "Adds an invisible extended display (for screen recording, streaming, or testing)."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if !controller.standaloneVirtualDisplays.isEmpty {
                        VStack(spacing: 5) {
                            ForEach(controller.standaloneVirtualDisplays) { v in
                                HStack {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(v.name)
                                            .font(.caption.weight(.medium))
                                        Text(L("최대 \(v.maxWidth)×\(v.maxHeight)", "Up to \(v.maxWidth)×\(v.maxHeight)"))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button(role: .destructive) {
                                        controller.removeVirtualDisplay(id: v.id)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel(L("\(v.name) 제거", "Remove \(v.name)"))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        Picker(L("비율", "Aspect ratio"), selection: $selectedPreset) {
                            ForEach(VirtualDisplayPreset.allCases) { preset in
                                Text(preset.label).tag(preset)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)

                        Button(L("추가", "Add")) {
                            controller.createStandaloneVirtualDisplay(preset: selectedPreset)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.top, 6)
            } label: {
                Text(L("고급 · 독립 가상 디스플레이", "Advanced · Standalone virtual display"))
                    .font(.caption.weight(.semibold))
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text(L("단축키", "Shortcuts"))
                    .font(.caption.weight(.semibold))
                shortcutRow(L("☀ 밝기 키 · F14 / F15", "☀ keys · F14 / F15"), L("대상 화면 밝기 조절", "Adjust target display brightness"))
                shortcutRow(L("표준 F1 / F2", "Standard F1 / F2"), controller.captureStandardKeys ? L("halo에서 사용 중", "Used by halo") : L("비활성", "Off"))
                shortcutRow(L("⌥⇧ 밝기 키", "⌥⇧ + ☀ keys"), L("1/64 단위 미세 밝기 조절", "Fine 1/64-step brightness"))
                shortcutRow("⌃⌥↑ / ⌃⌥↓", controller.captureCtrlOptionArrows ? L("외장 키보드 대체 키", "Alternate keys for external keyboards") : L("비활성", "Off"))
            }

            Divider()

            HStack {
                Button(L("권한 설정 열기", "Open Permission Settings")) {
                    controller.requestAccessibilityPermission()
                }
                .controlSize(.small)

                Spacer()

                Button(L("halo 종료", "Quit halo")) {
                    NSApp.terminate(nil)
                }
                .controlSize(.small)
            }
        }
        .padding(14)
    }

    private func shortcutRow(_ keys: String, _ desc: String) -> some View {
        HStack {
            Text(keys)
                .font(.caption2.monospaced())
                .foregroundStyle(.primary)
            Spacer()
            Text(desc)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Display Card

private struct DisplayCardView: View {
    let display: DisplayItem
    let modeSourceDisplay: DisplayItem
    let isKeyTarget: Bool
    let keyTargetMode: BrightnessKeyTargetMode
    let mirrorState: VirtualMirrorState
    let previewPending: Bool
    let pendingRevert: PendingModeRevert?
    let isExpanded: Bool

    let onHoverChange: (Bool) -> Void
    let onToggleExpand: () -> Void
    let onBrightnessChange: (Double) -> Void
    let onBackendSelect: (BrightnessBackend) -> Void
    let onModeSelect: (DisplayModeItem) -> Void
    let onToggleVirtualHiDPI: () -> Void
    let onExportOverride: () -> Void
    let onRevertMode: () -> Void
    let onKeepMode: () -> Void

    @State private var hiDPIOnly: Bool = true
    @State private var showAdvancedDrawer: Bool = false

    private var hasNativeHiDPI: Bool {
        modeSourceDisplay.modes.contains { $0.isHiDPI }
    }

    private var filteredModes: [DisplayModeItem] {
        let hiDPI = modeSourceDisplay.modes.filter { $0.isHiDPI }
        if hiDPIOnly && !hiDPI.isEmpty {
            return hiDPI
        }
        return modeSourceDisplay.modes
    }

    private var targetBadgeText: String? {
        guard isKeyTarget else { return nil }
        switch keyTargetMode {
        case .mouseCursor: return L("키 대상", "Key target")
        case .mainDisplay: return L("키 대상", "Key target")
        case .allDisplays: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Top Info Row
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: display.symbolName)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(isKeyTarget ? Color.accentColor : .secondary)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(display.name)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)

                        if let badge = targetBadgeText {
                            pillBadge(badge, color: .accentColor, filled: true)
                        }
                        if display.isMain && keyTargetMode != .mainDisplay {
                            pillBadge(L("메인", "Main"), color: .secondary, filled: false)
                        }
                        if mirrorState.isActive {
                            pillBadge(L("가상 HiDPI", "Virtual HiDPI"), color: .accentColor, filled: false)
                        }
                    }

                    Text(modeSourceDisplay.resolutionSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                // Resolution & Advanced drawer toggle (P1-4)
                Button(action: onToggleExpand) {
                    HStack(spacing: 3) {
                        Text(L("해상도", "Resolution"))
                            .font(.caption2.weight(.medium))
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(
                        isExpanded ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .foregroundStyle(isExpanded ? Color.accentColor : .primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("\(display.name) 해상도 설정", "\(display.name) resolution settings"))
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                onHoverChange(hovering)
            }

            // Brightness Control Row
            HStack(spacing: 8) {
                Image(systemName: display.brightness <= 0.1 ? "sun.min" : "sun.max.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)

                Slider(
                    value: Binding(
                        get: { display.brightness },
                        set: { onBrightnessChange($0) }
                    ),
                    in: 0.0...1.0
                )
                .controlSize(.small)
                .disabled(display.awaitingPreferredDDC)
                .accessibilityLabel(L("\(display.name) 밝기", "\(display.name) brightness"))
                .accessibilityValue(L("\(Int((display.brightness * 100).rounded()))퍼센트", "\(Int((display.brightness * 100).rounded())) percent"))

                Text("\(Int((display.brightness * 100).rounded()))%")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)

                Menu {
                    ForEach(display.supportedBackends) { backend in
                        Button {
                            onBackendSelect(backend)
                        } label: {
                            HStack {
                                Text(backend.displayName)
                                if backend == display.activeBackend {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text(display.activeBackend.shortLabel)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(backendTooltip)
                .accessibilityLabel(L("\(display.name) 밝기 제어 방식: \(display.activeBackend.displayName)", "\(display.name) brightness method: \(display.activeBackend.displayName)"))
            }

            // Inline error (P0-2)
            if let error = display.inlineError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Mirror overlay hint
            if display.isMirrored && display.activeBackend == .softwareOverlay {
                Text(L("소프트웨어 디밍은 미러링된 화면에 함께 적용됩니다.", "Software dimming also applies to mirrored displays."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Expanded Resolution & Advanced Drawer (P1-4, P1-8)
            if isExpanded {
                Divider()
                    .padding(.vertical, 1)

                VStack(alignment: .leading, spacing: 8) {
                    // Refresh rate Picker menu (P1-8: replaces hidden horizontal scroll)
                    if modeSourceDisplay.currentResolutionRefreshModes.count > 1 {
                        HStack {
                            Text(L("주사율", "Refresh rate"))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Picker(L("주사율", "Refresh rate"), selection: Binding(
                                get: {
                                    modeSourceDisplay.currentResolutionRefreshModes.first(where: { $0.isCurrent })?.id
                                        ?? modeSourceDisplay.currentResolutionRefreshModes.first?.id
                                        ?? ""
                                },
                                set: { selectedID in
                                    if let chosen = modeSourceDisplay.currentResolutionRefreshModes.first(where: { $0.id == selectedID }) {
                                        onModeSelect(chosen)
                                    }
                                }
                            )) {
                                ForEach(modeSourceDisplay.currentResolutionRefreshModes) { hzMode in
                                    Text(hzMode.refreshLabel).tag(hzMode.id)
                                }
                            }
                            .disabled(previewPending || mirrorState.isConnecting)
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .controlSize(.small)
                            .fixedSize()
                        }
                    }

                    // Filter Header
                    HStack {
                        Text(mirrorState.isActive ? L("가상 HiDPI 해상도", "Virtual HiDPI resolution") : L("해상도", "Resolution"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if hasNativeHiDPI {
                            Toggle(L("HiDPI만", "HiDPI only"), isOn: $hiDPIOnly)
                                .toggleStyle(.checkbox)
                                .controlSize(.mini)
                                .font(.caption2)
                        } else if !mirrorState.isActive {
                            Text(L("네이티브 HiDPI 없음 · 아래 고급에서 가상 HiDPI 사용", "No native HiDPI · see Advanced below"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Resolution List
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(filteredModes) { mode in
                                Button {
                                    onModeSelect(mode)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: mode.isCurrent ? "checkmark.circle.fill" : "circle")
                                            .font(.caption2)
                                            .foregroundStyle(mode.isCurrent ? Color.accentColor : .secondary.opacity(0.4))

                                        Text(mode.logicalLabel)
                                            .font(.caption.weight(mode.isCurrent ? .semibold : .regular))
                                            .monospacedDigit()

                                        // Only show HiDPI tag when mixed list is displayed (P1-8)
                                        if mode.isHiDPI && (!hiDPIOnly || !hasNativeHiDPI) {
                                            Text("HiDPI")
                                                .font(.caption2.weight(.semibold))
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 0.5)
                                                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 3.5))
                                                .foregroundStyle(Color.accentColor)
                                        }

                                        Spacer()

                                        Text(mode.refreshLabel)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4.5)
                                    .background(
                                        mode.isCurrent ? Color.accentColor.opacity(0.12) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6)
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(previewPending || mirrorState.isConnecting)
                            }
                        }
                    }
                    .frame(height: min(150, CGFloat(filteredModes.count) * 27))

                    // Keep / revert sits right under the list the user just clicked in.
                    if let pendingRevert {
                        ModeRevertPrompt(revert: pendingRevert, title: L("해상도 변경됨", "Resolution changed"),
                                         onRevert: onRevertMode, onKeep: onKeepMode)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                    }

                    // Advanced disclosure for external physical displays (P0-4, P1-4)
                    if !display.isBuiltIn && !display.isVirtual {
                        DisclosureGroup(isExpanded: $showAdvancedDrawer) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Button(action: onToggleVirtualHiDPI) {
                                        HStack(spacing: 5) {
                                            if mirrorState.isConnecting {
                                                ProgressView()
                                                    .controlSize(.mini)
                                                Text(L("가상 HiDPI 연결 취소", "Cancel Virtual HiDPI"))
                                            } else if mirrorState.isActive {
                                                Image(systemName: "rectangle.on.rectangle.slash")
                                                Text(L("가상 HiDPI 미러링 해제", "Turn Off Virtual HiDPI"))
                                            } else {
                                                Image(systemName: "rectangle.on.rectangle")
                                                Text(L("가상 HiDPI 미러링 켜기", "Turn On Virtual HiDPI"))
                                            }
                                        }
                                        .font(.caption.weight(.medium))
                                        .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(previewPending && !mirrorState.isConnecting)

                                    Button(L("설정 파일 저장", "Save Settings File"), action: onExportOverride)
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .help(L("영구 네이티브 HiDPI용 macOS Display Override 파일을 데스크톱에 저장합니다. 저장된 DisplayVendorID-… 폴더를 /Library/Displays/Contents/Resources/Overrides/ 에 복사한 뒤 재시동해야 적용됩니다.", "Saves a macOS Display Override file for permanent native HiDPI to the Desktop. Copy the saved DisplayVendorID-… folder into /Library/Displays/Contents/Resources/Overrides/ and restart to apply it."))
                                }

                                Text(L("가상 HiDPI 전환 시 화면이 1~2초 깜빡일 수 있습니다.", "The screen may flicker for 1–2 seconds when switching virtual HiDPI."))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)

                                if !display.ddcTechnicalDetail.isEmpty {
                                    Text(L("모니터 직접 제어 · \(display.ddcUserStatus)", "Direct monitor control · \(display.ddcUserStatus)"))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .help(display.ddcTechnicalDetail)
                                }
                            }
                            .padding(.top, 4)
                        } label: {
                            Text(L("고급 (가상 HiDPI · 설정 파일)", "Advanced (virtual HiDPI · settings file)"))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(
                    isKeyTarget ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.10),
                    lineWidth: isKeyTarget ? 1.25 : 0.75
                )
        )
        .onDisappear { onHoverChange(false) }
    }

    private var backendTooltip: String {
        var lines = [display.activeBackend.descriptionText]
        if !display.ddcTechnicalDetail.isEmpty {
            lines.append("DDC: " + display.ddcUserStatus)
            lines.append(display.ddcTechnicalDetail)
        }
        return lines.joined(separator: "\n")
    }

    private func pillBadge(_ text: String, color: Color, filled: Bool) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5.5)
            .padding(.vertical, 1)
            .background(
                filled ? color : color.opacity(0.14),
                in: Capsule()
            )
            .foregroundStyle(filled ? .white : color)
    }
}

// MARK: - Resolution Change Confirmation

/// Countdown with 되돌리기 / 유지, shared by the in-card prompt and the top fallback banner.
private struct ModeRevertPrompt: View {
    let revert: PendingModeRevert
    let title: String
    let onRevert: () -> Void
    let onKeep: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(revert.secondsRemaining > 0 ? L("\(revert.secondsRemaining)초 후 이전 해상도로 돌아갑니다.", "Reverting to the previous resolution in \(revert.secondsRemaining)s.") : L("복구에 실패했습니다. 되돌리기를 다시 시도하세요.", "Could not revert. Try Revert again."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(L("되돌리기", "Revert"), action: onRevert)
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button(L("유지", "Keep"), action: onKeep)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(revert.secondsRemaining == 0)
        }
    }
}
