import Foundation
import CoreGraphics
import AppKit

enum DisplayModeManager {
    /// Lists usable display modes deduplicated per logical resolution + HiDPI flag
    /// (picking the current mode or highest refresh rate), plus all refresh-rate variants for the current resolution.
    static func listModes(for displayID: CGDirectDisplayID) -> (modes: [DisplayModeItem], currentRefreshModes: [DisplayModeItem]) {
        let options: [CFString: Any] = [
            kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue as Any
        ]
        guard let rawModes = CGDisplayCopyAllDisplayModes(displayID, options as CFDictionary) as? [CGDisplayMode] else {
            return ([], [])
        }

        let currentMode = CGDisplayCopyDisplayMode(displayID)
        var bestByResolution: [String: DisplayModeItem] = [:]
        var refreshVariantsByHz: [Double: DisplayModeItem] = [:]

        for mode in rawModes {
            guard mode.isUsableForDesktopGUI() else { continue }
            let w = mode.width
            let h = mode.height
            let pw = mode.pixelWidth
            let ph = mode.pixelHeight
            let hz = mode.refreshRate
            let isHiDPI = (pw > w) || (ph > h)

            let resKey = "\(w)x\(h)_\(isHiDPI ? "hidpi" : "lodpi")"

            let isCurrent = currentMode?.ioDisplayModeID == mode.ioDisplayModeID
            let item = DisplayModeItem(
                id: String(mode.ioDisplayModeID),
                width: w,
                height: h,
                pixelWidth: pw,
                pixelHeight: ph,
                refreshRate: hz,
                isHiDPI: isHiDPI,
                isCurrent: isCurrent,
                cgMode: mode
            )

            // Collect refresh rate variants matching the current logical resolution & HiDPI state
            if let cur = currentMode,
               cur.width == w && cur.height == h && cur.pixelWidth == pw && cur.pixelHeight == ph {
                if let existingHz = refreshVariantsByHz[hz] {
                    if isCurrent || (!existingHz.isCurrent && pw > existingHz.pixelWidth) {
                        refreshVariantsByHz[hz] = item
                    }
                } else {
                    refreshVariantsByHz[hz] = item
                }
            }

            // Keep one representative mode per (logicalW, logicalH, isHiDPI): current first, else highest refresh rate
            if let existing = bestByResolution[resKey] {
                if isCurrent {
                    bestByResolution[resKey] = item
                } else if !existing.isCurrent && hz > existing.refreshRate {
                    bestByResolution[resKey] = item
                }
            } else {
                bestByResolution[resKey] = item
            }
        }

        let sortedModes = bestByResolution.values.sorted { lhs, rhs in
            if lhs.isHiDPI != rhs.isHiDPI {
                return lhs.isHiDPI && !rhs.isHiDPI
            }
            if lhs.width != rhs.width {
                return lhs.width > rhs.width
            }
            if lhs.height != rhs.height {
                return lhs.height > rhs.height
            }
            return lhs.refreshRate > rhs.refreshRate
        }

        let sortedRefreshModes = refreshVariantsByHz.values.sorted { $0.refreshRate > $1.refreshRate }
        return (sortedModes, sortedRefreshModes)
    }

    /// Switches the display to the chosen mode.
    @discardableResult
    static func applyMode(_ mode: CGDisplayMode, to displayID: CGDirectDisplayID, scope: CGConfigureOption) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else {
            return false
        }
        let err = CGConfigureDisplayWithDisplayMode(cfg, displayID, mode, nil)
        guard err == .success else {
            CGCancelDisplayConfiguration(cfg)
            return false
        }
        return CGCompleteDisplayConfiguration(cfg, scope) == .success
    }

    /// Generates a macOS Display Override plist (`scale-resolutions`) for persistent native HiDPI.
    /// Returns the plist XML Data and suggested install path.
    static func generateDisplayOverridePlist(
        vendorID: UInt32,
        productID: UInt32,
        displayName: String,
        logicalResolutions: [(Int, Int)]
    ) -> (data: Data, directoryName: String, fileName: String)? {
        let vendorHex = String(format: "%x", vendorID)
        let productHex = String(format: "%x", productID)

        // macOS scale-resolutions format: big-endian 32-bit width + height + flags (0x00000001 / 0x00200000 for HiDPI)
        var encodedResolutions: [Data] = []
        for (w, h) in logicalResolutions {
            guard w > 0, h > 0, w <= Int(UInt32.max / 2), h <= Int(UInt32.max / 2) else { return nil }
            let scaledW = UInt32(w * 2)
            let scaledH = UInt32(h * 2)

            // Entry 1: 2x HiDPI pixel entry with HiDPI flag (0x00000001, 0x00200000)
            var bytes = Data()
            var wBE = scaledW.bigEndian
            var hBE = scaledH.bigEndian
            var flag1 = UInt32(0x00000001).bigEndian
            var flag2 = UInt32(0x00200000).bigEndian
            bytes.append(Data(bytes: &wBE, count: 4))
            bytes.append(Data(bytes: &hBE, count: 4))
            bytes.append(Data(bytes: &flag1, count: 4))
            bytes.append(Data(bytes: &flag2, count: 4))
            encodedResolutions.append(bytes)

            // Entry 2: standard scaled entry
            var simple = Data()
            var lwBE = UInt32(w).bigEndian
            var lhBE = UInt32(h).bigEndian
            simple.append(Data(bytes: &lwBE, count: 4))
            simple.append(Data(bytes: &lhBE, count: 4))
            encodedResolutions.append(simple)
        }

        let plistDict: [String: Any] = [
            "DisplayProductName": "\(displayName) (HiDPI)",
            "DisplayVendorID": Int(vendorID),
            "DisplayProductID": Int(productID),
            "scale-resolutions": encodedResolutions
        ]

        guard let data = try? PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0) else {
            return nil
        }

        return (
            data: data,
            directoryName: "DisplayVendorID-\(vendorHex)",
            fileName: "DisplayProductID-\(productHex)"
        )
    }
}
