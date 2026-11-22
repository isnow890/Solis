import Foundation
import CoreGraphics
import AppKit

enum BrightnessBackend: String, CaseIterable, Codable, Identifiable {
    case native
    case ddc
    case softwareOverlay
    case softwareGamma

    var id: String { rawValue }

    var badgeText: String {
        switch self {
        case .native: return "Native"
        case .ddc: return "DDC"
        case .softwareOverlay: return "SW 오버레이"
        case .softwareGamma: return "SW 감마"
        }
    }

    var shortBadge: String {
        switch self {
        case .native: return "Native"
        case .ddc: return "DDC/CI"
        case .softwareOverlay: return "Overlay"
        case .softwareGamma: return "Gamma"
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
        case .allDisplays: return "전체 동기화"
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
        guard rate.isFinite, rate > 0 else { return "Hz 미보고" }
        return rate.formatted(.number.precision(.fractionLength(0...3))) + "Hz"
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
    var ddcState = "탐색 중"
    var awaitingPreferredDDC = false
    var ddcReadable = false
    var ddcMaxValue: UInt16
    var modes: [DisplayModeItem]
    var currentResolutionRefreshModes: [DisplayModeItem]

    var isHiDPI: Bool {
        pixelWidth > logicalWidth || scaleFactor >= 1.9
    }

    var isPortrait: Bool {
        logicalHeight > logicalWidth
    }

    var resolutionSummary: String {
        let hz = DisplayModeItem.label(for: refreshRate)
        let dpi = isHiDPI ? "HiDPI" : "LoDPI"
        return "\(logicalWidth)×\(logicalHeight) · \(dpi) · \(hz)"
    }

    var symbolName: String {
        if isVirtual {
            return "sparkles.rectangle.stack"
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

    /// Logical HiDPI resolutions exposed by CGVirtualDisplay (macOS doubles pixel backing when hiDPI=1)
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
