import SwiftUI
import CoreGraphics
import AppKit

struct MenuBarPopoverView: View {
    @ObservedObject var controller: DisplayController

    @State private var expandedDisplayIDs: Set<CGDirectDisplayID> = []
    @State private var showVirtualSection: Bool = false
    @State private var showSettings: Bool = false
    @State private var selectedPreset: VirtualDisplayPreset = .uhd16x9
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let needsScroll = contentHeight > controller.popoverAvailableHeight
        ScrollView(.vertical, showsIndicators: needsScroll) {
            popoverContents
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geometry in
                    Color.clear.onAppear { contentHeight = geometry.size.height }
                        .onChange(of: geometry.size.height) { _, height in contentHeight = height }
                })
        }
        .scrollDisabled(!needsScroll)
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 368, height: min(controller.popoverAvailableHeight,
                                      contentHeight > 0 ? contentHeight : controller.popoverAvailableHeight))
    }

    private var popoverContents: some View {
        VStack(spacing: 0) {
            headerBar

            Divider()

            if let banner = controller.statusBannerMessage {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                    Text(banner)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.accentColor.opacity(0.12))
                Divider()
            }

            if !controller.isAccessibilityGranted {
                accessibilityCallout
                Divider()
            }

            if showSettings {
                settingsPanel
            } else {
                mainContent
            }
        }
        .frame(width: 368)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text("Solis")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(controller.displays.count)개 디스플레이 연결됨")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                controller.refreshDisplays()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("디스플레이 목록 새로고침")

            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    showSettings.toggle()
                }
            } label: {
                Image(systemName: showSettings ? "gearshape.fill" : "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(showSettings ? Color.accentColor : .primary)
            }
            .buttonStyle(.borderless)
            .help("설정")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Solis 종료")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Accessibility Callout

    private var accessibilityHelp: String {
        if #available(macOS 27.3, *) {
            return "개인정보 보호 및 보안에서 Solis가 요청한 항목을 확인하세요. 27.3에서는 Accessibility와 System & App Protection Override가 분리됩니다."
        }
        if #available(macOS 27, *) {
            return "기기 제어 및 데이터 접근에서 Solis를 허용하세요. 변경 후 자동으로 다시 확인합니다."
        }
        return "손쉬운 사용에서 Solis를 허용하세요. 변경 후 자동으로 다시 확인합니다."
    }

    private var accessibilityCallout: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text("키보드 밝기 키 연동 필요")
                        .font(.system(size: 11, weight: .semibold))
                    Text(accessibilityHelp)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 6) {
                Button("권한 요청") {
                    controller.requestAccessibilityPermission()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("앱 재시작") {
                    controller.relaunchApp()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Text("AX:\(controller.keyStatus.accessibility ? "O" : "X") EV:\(controller.keyStatus.postEvent ? "O" : "X")")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
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
                .padding(.top, 9)
                .padding(.bottom, 7)

            displayListBody
        }
    }

    private var displayListBody: some View {
        VStack(spacing: 8) {
            ForEach(controller.displays) { display in
                DisplayCardView(
                    display: display,
                    isCursorHere: controller.cursorDisplayID == display.id,
                    isVirtualMirrorActive: controller.virtualDisplayManager.mirrorRecord(forPhysicalDisplayID: display.id) != nil,
                    isExpanded: expandedDisplayIDs.contains(display.id),
                    onToggleExpand: {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            if expandedDisplayIDs.contains(display.id) {
                                expandedDisplayIDs.remove(display.id)
                            } else {
                                expandedDisplayIDs.insert(display.id)
                            }
                        }
                    },
                    onBrightnessChange: { newVal in
                        controller.setBrightness(newVal, for: display.id, showOSD: false)
                    },
                    onBackendSelect: { backend in
                        controller.switchBackend(backend, for: display.id)
                    },
                    onModeSelect: { mode in
                        controller.applyDisplayMode(mode, for: display.id)
                    },
                    onToggleVirtualHiDPI: {
                        controller.toggleVirtualHiDPIMirror(for: display)
                    },
                    onExportOverride: {
                        controller.exportDisplayOverridePlist(for: display)
                    }
                )
            }

            virtualDisplaySection
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)

    }

    // MARK: - Brightness Key Target Strip

    private var keyTargetStrip: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label("밝기 키 대상", systemImage: "keyboard")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(controller.captureStandardKeys ? "F1/F2 · ⌃⌥↑↓" : "밝기 키 · ⌃⌥↑↓")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Picker("", selection: $controller.keyTargetMode) {
                ForEach(BrightnessKeyTargetMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // MARK: - Virtual Display Section

    private var virtualDisplaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    showVirtualSection.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.purple)
                    Text("가상 HiDPI 디스플레이")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.primary)
                    if !controller.virtualDisplays.isEmpty {
                        Text("\(controller.virtualDisplays.count)")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.18), in: Capsule())
                            .foregroundStyle(.purple)
                    }
                    Spacer()
                    Image(systemName: showVirtualSection ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showVirtualSection {
                Divider()

                if !controller.virtualDisplays.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(controller.virtualDisplays) { v in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(v.name)
                                        .font(.system(size: 11, weight: .medium))
                                    if let mirroredName = v.mirroredPhysicalDisplayName {
                                        Text("\(mirroredName) \(controller.virtualDisplayManager.isPending(v.id) ? "연결 중" : "미러") · 최대 \(v.maxWidth)×\(v.maxHeight)")
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text("독립 가상 화면 · 최대 \(v.maxWidth)×\(v.maxHeight)")
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    controller.removeVirtualDisplay(id: v.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11))
                                }
                                .buttonStyle(.borderless)
                                .help("가상 디스플레이 제거")
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
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
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.75)
        )
    }

    // MARK: - Settings Panel

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("앱 설정")
                .font(.system(size: 12, weight: .semibold))

            Toggle(isOn: Binding(
                get: { controller.launchAtLogin },
                set: { controller.setLaunchAtLogin($0) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("로그인 시 자동 실행")
                        .font(.system(size: 12))
                    Text("macOS 시작 시 상단 메뉴바에 자동으로 띄웁니다.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if controller.loginNeedsApproval {
                Button("로그인 항목 설정에서 승인", action: controller.openLoginSettings)
            }
            Toggle("표준 F1/F2로 화면 밝기 조절", isOn: $controller.captureStandardKeys)
                .toggleStyle(.switch)
                .controlSize(.small)
            Toggle(isOn: $controller.cleanupVirtualOnQuit) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("종료 전에 기존 미러 관계 복구")
                        .font(.system(size: 12))
                    Text("가상 화면은 앱 종료와 함께 사라집니다. 켜면 종료 전에 이전 미러 관계를 명시적으로 복구합니다.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("키보드 이벤트 탭")
                        .font(.system(size: 11.5, weight: .medium))
                    Text(controller.isAccessibilityGranted ? "활성 · 필요한 키 이벤트 수신 가능" : "일부 키 이벤트를 받을 수 없음")
                        .font(.system(size: 10))
                        .foregroundStyle(controller.isAccessibilityGranted ? .green : .orange)
                }
                Spacer()
                Button("시스템 설정") {
                    BrightnessKeyMonitor.openAccessibilitySettings()
                }
                .controlSize(.small)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("단축키 안내")
                    .font(.system(size: 11, weight: .semibold))
                shortcutRow("☀ 밝기 키 · F14 / F15", "선택한 화면 밝기 조절")
                shortcutRow("표준 F1 / F2", controller.captureStandardKeys ? "Solis에서 사용" : "다른 앱에서 사용")
                shortcutRow("⌥ + ⇧ + 밝기 키", "1/4 미세 밝기 조절")
                shortcutRow("⌃ + ⌥ + ↑ / ↓", "외장 키보드용 밝기 조절")
            }

            HStack {
                Spacer()
                Button("완료") {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showSettings = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(14)
    }

    private func shortcutRow(_ keys: String, _ desc: String) -> some View {
        HStack {
            Text(keys)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.primary)
            Spacer()
            Text(desc)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Display Card

private struct DisplayCardView: View {
    let display: DisplayItem
    let isCursorHere: Bool
    let isVirtualMirrorActive: Bool
    let isExpanded: Bool

    let onToggleExpand: () -> Void
    let onBrightnessChange: (Double) -> Void
    let onBackendSelect: (BrightnessBackend) -> Void
    let onModeSelect: (DisplayModeItem) -> Void
    let onToggleVirtualHiDPI: () -> Void
    let onExportOverride: () -> Void

    @State private var hiDPIOnly: Bool = true

    private var filteredModes: [DisplayModeItem] {
        let hiDPI = display.modes.filter { $0.isHiDPI }
        if hiDPIOnly && !hiDPI.isEmpty {
            return hiDPI
        }
        return display.modes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Top Info Row
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: display.symbolName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isCursorHere ? Color.accentColor : .secondary)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(display.name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)

                        if isCursorHere {
                            pillBadge("커서", color: .accentColor, filled: true)
                        }
                        if display.isMain {
                            pillBadge("메인", color: .secondary, filled: false)
                        }
                        if display.isBuiltIn {
                            pillBadge("내장", color: .secondary, filled: false)
                        }
                        if display.isVirtual {
                            pillBadge("가상", color: .purple, filled: false)
                        }
                    }

                    Text(display.resolutionSummary)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                // Expand button for HiDPI / Resolution
                Button(action: onToggleExpand) {
                    HStack(spacing: 3) {
                        Text("HiDPI")
                            .font(.system(size: 10, weight: .medium))
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
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
            }

            // Brightness Control Row
            HStack(spacing: 8) {
                Image(systemName: display.brightness <= 0.1 ? "sun.min" : "sun.max.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
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

                Text("\(Int((display.brightness * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)

                Menu {
                    ForEach(display.supportedBackends) { backend in
                        Button {
                            onBackendSelect(backend)
                        } label: {
                            HStack {
                                Text(backend.badgeText)
                                if backend == display.activeBackend {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text(display.activeBackend.shortBadge)
                        .font(.system(size: 9.5, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("밝기 제어 방식 선택")
            }

            if display.awaitingPreferredDDC || display.activeBackend == .ddc || (isExpanded && !display.isBuiltIn && !display.isVirtual) {
                Text("DDC/CI · " + display.ddcState)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if display.isMirrored && display.activeBackend == .softwareOverlay {
                Text("오버레이는 같은 미러 그룹의 화면에 함께 적용됩니다.")
                    .font(.caption2)
            }

            // Expanded HiDPI & Resolution Drawer
            if isExpanded {
                Divider()
                    .padding(.vertical, 1)

                VStack(alignment: .leading, spacing: 8) {
                    // Virtual HiDPI Mirror action for external physical displays
                    if !display.isBuiltIn && !display.isVirtual {
                        HStack(spacing: 6) {
                            Button(action: onToggleVirtualHiDPI) {
                                HStack(spacing: 5) {
                                    Image(systemName: isVirtualMirrorActive ? "rectangle.on.rectangle.slash" : "sparkles")
                                        .font(.system(size: 10.5))
                                    Text(isVirtualMirrorActive ? "가상 HiDPI 미러링 해제" : "가상 HiDPI 미러링 켜기")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(isVirtualMirrorActive ? .orange : .purple)
                            .controlSize(.small)

                            Button(action: onExportOverride) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("macOS Display Override(.plist) 파일 내보내기")
                        }
                    }

                    // Refresh rate selector if current resolution supports multiple Hz
                    if display.currentResolutionRefreshModes.count > 1 {
                        HStack(spacing: 6) {
                            Text("주사율")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 4) {
                                    ForEach(display.currentResolutionRefreshModes) { hzMode in
                                        Button {
                                            onModeSelect(hzMode)
                                        } label: {
                                            Text(hzMode.refreshLabel)
                                                .font(.system(size: 10, weight: hzMode.isCurrent ? .semibold : .regular, design: .rounded))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2.5)
                                                .background(
                                                    hzMode.isCurrent ? Color.accentColor : Color.primary.opacity(0.07),
                                                    in: RoundedRectangle(cornerRadius: 5)
                                                )
                                                .foregroundStyle(hzMode.isCurrent ? .white : .primary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }

                    // Filter Header
                    HStack {
                        Text("해상도 목록")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        let hasHiDPI = display.modes.contains { $0.isHiDPI }
                        if hasHiDPI {
                            Toggle("HiDPI만", isOn: $hiDPIOnly)
                                .toggleStyle(.checkbox)
                                .controlSize(.mini)
                                .font(.system(size: 10))
                        } else {
                            Text("네이티브 HiDPI 없음 · 위 가상 HiDPI 추천")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.orange)
                        }
                    }

                    // Resolution List
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(filteredModes) { mode in
                                Button {
                                    onModeSelect(mode)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: mode.isCurrent ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(mode.isCurrent ? Color.accentColor : .secondary.opacity(0.4))

                                        Text(mode.logicalLabel)
                                            .font(.system(size: 11, weight: mode.isCurrent ? .semibold : .regular, design: .rounded))
                                            .monospacedDigit()

                                        if mode.isHiDPI {
                                            Text("HiDPI")
                                                .font(.system(size: 8.5, weight: .bold))
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(Color.blue.opacity(0.16), in: RoundedRectangle(cornerRadius: 3.5))
                                                .foregroundStyle(.blue)
                                        }

                                        Spacer()

                                        Text(mode.refreshLabel)
                                            .font(.system(size: 10, design: .rounded))
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
                            }
                        }
                    }
                    .frame(maxHeight: 155)
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(
                    isCursorHere ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08),
                    lineWidth: isCursorHere ? 1.2 : 0.75
                )
        )
    }

    private func pillBadge(_ text: String, color: Color, filled: Bool) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                filled ? color : color.opacity(0.14),
                in: Capsule()
            )
            .foregroundStyle(filled ? .white : color)
    }
}
