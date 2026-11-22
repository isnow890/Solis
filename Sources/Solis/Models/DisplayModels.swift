import Foundation
import CoreGraphics
import AppKit

enum BrightnessBackend: String, CaseIterable, Codable, Identifiable {
    case native
    case ddc
    case softwareOverlay
    case softwareGamma

    var id: String { rawValue }

    /// Unified user-facing label used across menus and tooltips.
    var displayName: String {
        switch self {
        case .native: return "하드웨어"
        case .ddc: return "모니터(DDC)"
        case .softwareOverlay: return "소프트웨어 디밍"
        case .softwareGamma: return "감마 디밍"
        }
    }

    var shortLabel: String {
        switch self {
        case .native: return "하드웨어"
        case .ddc: return "DDC"
        case .softwareOverlay: return "소프트웨어"
        case .softwareGamma: return "감마"
        }
    }

    var descriptionText: String {
        switch self {
        case .native: return "macOS 기본 백라이트 제어"
        case .ddc: return "모니터 자체 백라이트 직접 제어"
        case .softwareOverlay: return "반투명 오버레이로 화면 어둡게 표시"
        case .softwareGamma: return "색상 테이블(LUT) 조절로 화면 어둡게 표시"
        }
    }
}

enum BrightnessKeyTargetMode: String, CaseIterable, Codable, Identifiable {
    case mouseCursor
    case allDisplays
    case mainDisplay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mouseCursor: return "마우스 위치"
        case .allDisplays: return "모든 화면"
        case .mainDisplay: return "메인 화면"
        }
    }

    var iconName: String {
        switch self {
        case .mouseCursor: return "cursorarrow.rays"
        case .allDisplays: return "rectangle.3.group"
        case .mainDisplay: return "macwindow"
        }
    }
}

struct StatusBanner: Equatable, Identifiable {
    enum Level: Equatable {
        case info
        case success
        case warning
        case error
    }

    let id = UUID()
    let level: Level
    let message: String
    let autoDismiss: Bool
}

enum VirtualMirrorState: Equatable {
    case idle
    case connecting
    case active
    case failed(String)

    var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }

    var isActive: Bool {
        if case .active = self { return true }
        return false
    }
}

struct PendingModeRevert: Equatable {
    let displayID: CGDirectDisplayID
    let displayName: String
    let previousMode: CGDisplayMode
    var secondsRemaining: Int

    static func == (lhs: PendingModeRevert, rhs: PendingModeRevert) -> Bool {
        lhs.displayID == rhs.displayID &&
        lhs.secondsRemaining == rhs.secondsRemaining &&
        lhs.previousMode.ioDisplayModeID == rhs.previousMode.ioDisplayModeID
    }
}

struct DisplayModeItem: Identifiable, Hashable {
    let id: String
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
    let isHiDPI: Bool
    let isCurrent: Bool
    let cgMode: CGDisplayMode

    var logicalLabel: String {
        "\(width) × \(height)"
    }

    var refreshLabel: String {
        Self.label(for: refreshRate)
    }

    static func label(for rate: Double) -> String {
        guard rate.isFinite, rate > 0 else { return "주사율 미보고" }
        return rate.formatted(.number.precision(.fractionLength(0...2))) + "Hz"
    }

    static func == (lhs: DisplayModeItem, rhs: DisplayModeItem) -> Bool {
        lhs.id == rhs.id && lhs.isCurrent == rhs.isCurrent
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct DisplayItem: Identifiable {
    let id: CGDirectDisplayID
    let uuidString: String
    let name: String
    let vendorID: UInt32
    let productID: UInt32
    let serialNumber: UInt32
    let isBuiltIn: Bool
    let isMain: Bool
    let isVirtual: Bool
    let isMirrored: Bool
    let mirrorMasterID: CGDirectDisplayID?
    let frameMinX: CGFloat

    let logicalWidth: Int
    let logicalHeight: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let scaleFactor: CGFloat
    let refreshRate: Double
    let rotation: Double

    var brightness: Double
    var activeBackend: BrightnessBackend
    var supportedBackends: [BrightnessBackend]
    var ddcUserStatus = "확인 중"
    var ddcTechnicalDetail = ""
    var awaitingPreferredDDC = false
    var ddcReadable = false
    var ddcMaxValue: UInt16
    var modes: [DisplayModeItem]
    var currentResolutionRefreshModes: [DisplayModeItem]
    var inlineError: String?

    var isHiDPI: Bool {
        pixelWidth > logicalWidth || scaleFactor >= 1.9
    }

    var isPortrait: Bool {
        logicalHeight > logicalWidth
    }

    var resolutionSummary: String {
        let hz = DisplayModeItem.label(for: refreshRate)
        if isHiDPI {
            return "\(logicalWidth)×\(logicalHeight) · HiDPI · \(hz)"
        }
        return "\(logicalWidth)×\(logicalHeight) · \(hz)"
    }

    var symbolName: String {
        if isVirtual {
            return "rectangle.dashed"
        }
        if isBuiltIn {
            return "laptopcomputer"
        }
        if isPortrait {
            return "display.and.arrow.down"
        }
        return "display"
    }
}

enum VirtualDisplayPreset: String, CaseIterable, Identifiable {
    case uhd16x9 = "16:9 (4K HiDPI)"
    case qhd16x10 = "16:10 (WQXGA HiDPI)"
    case ultrawide21x9 = "21:9 (Ultrawide HiDPI)"
    case portrait9x16 = "9:16 (세로 HiDPI)"

    var id: String { rawValue }

    var maxPixels: (width: Int, height: Int) {
        switch self {
        case .uhd16x9: return (3840, 2160)
        case .qhd16x10: return (3840, 2400)
        case .ultrawide21x9: return (5120, 2160)
        case .portrait9x16: return (2160, 3840)
        }
    }

    var sizeInMM: CGSize {
        switch self {
        case .uhd16x9: return CGSize(width: 600, height: 340)
        case .qhd16x10: return CGSize(width: 560, height: 350)
        case .ultrawide21x9: return CGSize(width: 800, height: 340)
        case .portrait9x16: return CGSize(width: 340, height: 600)
        }
    }

    var logicalModes: [(width: Int, height: Int, hz: Double)] {
        switch self {
        case .uhd16x9:
            return [
                (1920, 1080, 60),
                (1600, 900, 60),
                (1440, 810, 60),
                (1280, 720, 60)
            ]
        case .qhd16x10:
            return [
                (1920, 1200, 60),
                (1680, 1050, 60),
                (1440, 900, 60),
                (1280, 800, 60)
            ]
        case .ultrawide21x9:
            return [
                (2560, 1080, 60),
                (2150, 900, 60),
                (1920, 810, 60)
            ]
        case .portrait9x16:
            return [
                (1080, 1920, 60),
                (900, 1600, 60),
                (720, 1280, 60)
            ]
        }
    }
}

struct ManagedVirtualDisplayInfo: Identifiable {
    let id: UUID
    let displayID: CGDirectDisplayID
    let name: String
    let maxWidth: Int
    let maxHeight: Int
    let mirroredPhysicalDisplayID: CGDirectDisplayID?
    let mirroredPhysicalDisplayName: String?
}
