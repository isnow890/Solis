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
        let available = max(1, controller.popoverAvailableHeight - (controller.pendingModeRevert == nil ? 0 : confirmationHeight))
        let needsScroll = contentHeight > available
        VStack(spacing: 0) {
            if let revert = controller.pendingModeRevert {
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
                HStack {
                    Text("Solis \(release.version) 업데이트")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Link("릴리즈 열기", destination: release.url)
                    Button("이 버전 건너뛰기", action: updates.skip)
                }
                .font(.caption)
                .controlSize(.small)
                .padding(10)
                .background(Color.accentColor.opacity(0.10))
                Divider()
            }
            if let message = updates.manualMessage {
                HStack {
                    Text(message).font(.caption)
                    Spacer()
                    Button { updates.manualMessage = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("업데이트 알림 닫기")
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
            Text("Solis")
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
            .help("설정")
            .accessibilityLabel("설정")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Mode Revert Safety Banner (P1-7)

    private func modeRevertBanner(_ revert: PendingModeRevert) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(revert.displayName) 해상도 변경됨")
                    .font(.caption.weight(.semibold))
                Text(revert.secondsRemaining > 0 ? "\(revert.secondsRemaining)초 후 이전 해상도로 돌아갑니다." : "복구에 실패했습니다. 되돌리기를 다시 시도하세요.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("되돌리기") {
                controller.revertPendingMode()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button("유지") {
                controller.keepPendingMode()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(revert.secondsRemaining == 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
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
                .accessibilityLabel("알림 닫기")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.11))
    }

    // MARK: - Accessibility Callout (P0-1, P0-7)

    private var accessibilityHelp: String {
        if controller.needsPermissionRelaunch {
            return "권한은 켜져 있지만 연결이 갱신되지 않았습니다. 앱을 재시작하거나, 설정에서 기존 Solis를 (−)로 삭제 후 다시 허용해 주세요."
        }
        return "슬라이더와 해상도는 권한 없이도 바로 쓸 수 있습니다. 키보드 밝기 키만 권한이 필요합니다."
    }

    private var permissionSettingsHint: String {
        if #available(macOS 27.3, *) {
            return "개인정보 보호 및 보안에서 Solis가 요청한 항목을 확인하세요."
        }
        if #available(macOS 27, *) { return "개인정보 보호 및 보안 > 기기 제어 및 데이터 접근" }
        return "개인정보 보호 및 보안 > 손쉬운 사용"
    }

    private var accessibilityCallout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.needsPermissionRelaunch ? "키보드 밝기 키 연결 대기" : "키보드 밝기 키 권한 필요")
                        .font(.caption.weight(.semibold))
                    Text(accessibilityHelp)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 6) {
                if controller.needsPermissionRelaunch {
                    Button("앱 재시작", action: controller.relaunchApp)
                        .buttonStyle(.borderedProminent)
                    Button("설정 열기", action: controller.requestAccessibilityPermission)
                } else {
                    Button("권한 허용", action: controller.requestAccessibilityPermission)
                        .buttonStyle(.borderedProminent)
                    Button("나중에") { controller.permissionBannerDeferred = true }
                }
            }
            .controlSize(.small)
            .help(permissionSettingsHint)
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
                    DisplayCardView(
                        display: display,
                        isKeyTarget: controller.isKeyTarget(display.id),
                        keyTargetMode: controller.keyTargetMode,
                        mirrorState: controller.mirrorState(for: display.id),
                        previewPending: controller.pendingModeRevert != nil,
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
                            controller.applyDisplayMode(mode, for: display)
                        },
                        onToggleVirtualHiDPI: {
                            controller.toggleVirtualHiDPIMirror(for: display)
                        },
                        onExportOverride: {
                            controller.exportDisplayOverridePlist(for: display)
                        }
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
                Label("키보드 밝기 대상", systemImage: "keyboard")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(shortcutSummaryText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }

            Picker("키보드 밝기 대상", selection: $controller.keyTargetMode) {
                ForEach(BrightnessKeyTargetMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!controller.isAccessibilityGranted)
            if !controller.isAccessibilityGranted {
                HStack {
                    Text("밝기 키 연결 후 대상을 선택할 수 있습니다.")
                    Spacer()
                    if controller.permissionBannerDeferred {
                        Button("권한 안내") { controller.permissionBannerDeferred = false }
                            .buttonStyle(.link)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var shortcutSummaryText: String {
        let base = controller.captureStandardKeys ? "F1/F2" : "밝기 키"
        return controller.captureCtrlOptionArrows ? "\(base) · ⌃⌥↑↓" : base
    }

    // MARK: - Settings Panel (P0-5, P0-6, P1-9, P2)

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("설정")
                .font(.callout.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: Binding(
                    get: { controller.launchAtLogin },
                    set: { controller.setLaunchAtLogin($0) }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("로그인 시 자동 실행")
                            .font(.callout)
                        Text("macOS 시작 시 상단 메뉴바에 자동으로 실행합니다.")
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
                        Text("승인 대기 · 로그인 항목에서 Solis를 켜주세요")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("열기", action: controller.openLoginSettings)
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                }
            }

            HStack {
                Toggle("업데이트 자동 확인", isOn: $updates.automaticallyChecks)
                    .toggleStyle(.switch)
                Spacer()
                Button(updates.checking ? "확인 중…" : "업데이트 확인…", action: updates.checkManually)
                    .disabled(updates.checking)
            }
            .controlSize(.small)

            Toggle(isOn: $controller.captureStandardKeys) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("표준 F1 / F2로 밝기 조절")
                        .font(.callout)
                    Text("켜면 다른 앱의 F1/F2 단축키 대신 Solis 밝기 조절이 동작합니다.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle(isOn: $controller.captureCtrlOptionArrows) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("⌃⌥↑ / ⌃⌥↓ 대체 단축키 사용")
                        .font(.callout)
                    Text("Rectangle 등 창 관리 앱과 충돌하면 끌 수 있습니다.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle(isOn: $controller.cleanupVirtualOnQuit) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("종료 시 기존 미러 구성 복구")
                        .font(.callout)
                    Text("가상 화면은 앱 종료 시 사라지며, 켜면 이전 미러 배치를 명시적으로 복원합니다.")
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
                    Text("보이지 않는 확장 화면이 추가됩니다 (화면 녹화·스트리밍·테스트용).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if !controller.standaloneVirtualDisplays.isEmpty {
                        VStack(spacing: 5) {
                            ForEach(controller.standaloneVirtualDisplays) { v in
                                HStack {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(v.name)
                                            .font(.caption.weight(.medium))
                                        Text("최대 \(v.maxWidth)×\(v.maxHeight)")
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
                                    .accessibilityLabel("\(v.name) 제거")
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        Picker("비율", selection: $selectedPreset) {
                            ForEach(VirtualDisplayPreset.allCases) { preset in
                                Text(preset.rawValue).tag(preset)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)

                        Button("추가") {
                            controller.createStandaloneVirtualDisplay(preset: selectedPreset)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("고급 · 독립 가상 디스플레이")
                    .font(.caption.weight(.semibold))
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("단축키")
                    .font(.caption.weight(.semibold))
                shortcutRow("☀ 밝기 키 · F14 / F15", "대상 화면 밝기 조절")
                shortcutRow("표준 F1 / F2", controller.captureStandardKeys ? "Solis에서 사용 중" : "비활성")
                shortcutRow("⌥⇧ 밝기 키", "1/4 미세 밝기 조절")
                shortcutRow("⌃⌥↑ / ⌃⌥↓", controller.captureCtrlOptionArrows ? "외장 키보드 대체 키" : "비활성")
            }

            Divider()

            HStack {
                Button("권한 설정 열기") {
                    controller.requestAccessibilityPermission()
                }
                .controlSize(.small)

                Spacer()

                Button("Solis 종료") {
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
    let isKeyTarget: Bool
    let keyTargetMode: BrightnessKeyTargetMode
    let mirrorState: VirtualMirrorState
    let previewPending: Bool
    let isExpanded: Bool

    let onHoverChange: (Bool) -> Void
    let onToggleExpand: () -> Void
    let onBrightnessChange: (Double) -> Void
    let onBackendSelect: (BrightnessBackend) -> Void
    let onModeSelect: (DisplayModeItem) -> Void
    let onToggleVirtualHiDPI: () -> Void
    let onExportOverride: () -> Void

    @State private var hiDPIOnly: Bool = true
    @State private var showAdvancedDrawer: Bool = false

    private var hasNativeHiDPI: Bool {
        display.modes.contains { $0.isHiDPI }
    }

    private var filteredModes: [DisplayModeItem] {
        let hiDPI = display.modes.filter { $0.isHiDPI }
        if hiDPIOnly && !hiDPI.isEmpty {
            return hiDPI
        }
        return display.modes
    }

    private var targetBadgeText: String? {
        guard isKeyTarget else { return nil }
        switch keyTargetMode {
        case .mouseCursor: return "키 대상"
        case .mainDisplay: return "키 대상"
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
                            pillBadge("메인", color: .secondary, filled: false)
                        }
                        if mirrorState.isActive {
                            pillBadge("가상 HiDPI", color: .accentColor, filled: false)
                        }
                    }

                    Text(display.resolutionSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                // Resolution & Advanced drawer toggle (P1-4)
                Button(action: onToggleExpand) {
                    HStack(spacing: 3) {
                        Text("해상도")
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
                .accessibilityLabel("\(display.name) 해상도 설정")
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
                .accessibilityLabel("\(display.name) 밝기")
                .accessibilityValue("\(Int((display.brightness * 100).rounded()))퍼센트")

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
                .accessibilityLabel("\(display.name) 밝기 제어 방식: \(display.activeBackend.displayName)")
            }

            // Inline error (P0-2)
            if let error = display.inlineError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Mirror overlay hint
            if display.isMirrored && display.activeBackend == .softwareOverlay {
                Text("소프트웨어 디밍은 미러링된 화면에 함께 적용됩니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Expanded Resolution & Advanced Drawer (P1-4, P1-8)
            if isExpanded {
                Divider()
                    .padding(.vertical, 1)

                VStack(alignment: .leading, spacing: 8) {
                    // Refresh rate Picker menu (P1-8: replaces hidden horizontal scroll)
                    if display.currentResolutionRefreshModes.count > 1 {
                        HStack {
                            Text("주사율")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Picker("주사율", selection: Binding(
                                get: {
                                    display.currentResolutionRefreshModes.first(where: { $0.isCurrent })?.id
                                        ?? display.currentResolutionRefreshModes.first?.id
                                        ?? ""
                                },
                                set: { selectedID in
                                    if let chosen = display.currentResolutionRefreshModes.first(where: { $0.id == selectedID }) {
                                        onModeSelect(chosen)
                                    }
                                }
                            )) {
                                ForEach(display.currentResolutionRefreshModes) { hzMode in
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
                        Text("해상도")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if hasNativeHiDPI {
                            Toggle("HiDPI만", isOn: $hiDPIOnly)
                                .toggleStyle(.checkbox)
                                .controlSize(.mini)
                                .font(.caption2)
                        } else {
                            Text("네이티브 HiDPI 없음 · 아래 고급에서 가상 HiDPI 사용")
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
                                                Text("가상 HiDPI 연결 취소")
                                            } else if mirrorState.isActive {
                                                Image(systemName: "rectangle.on.rectangle.slash")
                                                Text("가상 HiDPI 미러링 해제")
                                            } else {
                                                Image(systemName: "rectangle.on.rectangle")
                                                Text("가상 HiDPI 미러링 켜기")
                                            }
                                        }
                                        .font(.caption.weight(.medium))
                                        .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(previewPending && !mirrorState.isConnecting)

                                    Button("설정 파일 저장", action: onExportOverride)
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .help("영구 네이티브 HiDPI용 macOS Display Override 파일을 데스크톱에 저장합니다.")
                                }

                                Text("가상 HiDPI 전환 시 화면이 1~2초 깜빡일 수 있습니다.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)

                                if !display.ddcTechnicalDetail.isEmpty {
                                    Text("모니터 직접 제어 · \(display.ddcUserStatus)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .help(display.ddcTechnicalDetail)
                                }
                            }
                            .padding(.top, 4)
                        } label: {
                            Text("고급 (가상 HiDPI · 설정 파일)")
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
        .onHover { hovering in
            onHoverChange(hovering)
        }
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
