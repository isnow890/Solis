import Foundation
import CoreGraphics
import CDisplayBridge

@MainActor
final class VirtualDisplayManager {
    private struct ActiveRecord {
        let id: UUID
        let handle: LDVirtualDisplayHandle
        let name: String
        let maxWidth: Int
        let maxHeight: Int
        var mirroredPhysicalDisplayID: CGDirectDisplayID?
        var mirroredPhysicalDisplayName: String?
    }

    private var records: [UUID: ActiveRecord] = [:]
    private struct MirrorRequest {
        let physicalUUID: String
        let previousMaster: CGDirectDisplayID
        let previousMasterUUID: String?
        var committed = false
        var completion: ((Bool, String?) -> Void)?
    }

    private var mirrors: [UUID: MirrorRequest] = [:]
    private var pending: [UUID: DispatchWorkItem] = [:]
    private var nextSerial: UInt32 = 1001

    var isSupported: Bool {
        LDVirtualDisplayHandle.isSupported()
    }

    var activeVirtualDisplays: [ManagedVirtualDisplayInfo] {
        records.values
            .sorted { $0.name < $1.name }
            .map {
                ManagedVirtualDisplayInfo(
                    id: $0.id,
                    displayID: $0.handle.displayID,
                    name: $0.name,
                    maxWidth: $0.maxWidth,
                    maxHeight: $0.maxHeight,
                    mirroredPhysicalDisplayID: $0.mirroredPhysicalDisplayID,
                    mirroredPhysicalDisplayName: $0.mirroredPhysicalDisplayName
                )
            }
    }

    func virtualDisplayIDSet() -> Set<CGDirectDisplayID> {
        Set(records.values.map { $0.handle.displayID })
    }

    func mirrorRecord(forPhysicalDisplayID physicalID: CGDirectDisplayID) -> ManagedVirtualDisplayInfo? {
        activeVirtualDisplays.first { $0.mirroredPhysicalDisplayID == physicalID }
    }

    /// A user can unplug the target or change the mirror in System Settings.
    /// Expose the surviving virtual display in Settings so it can still be removed.
    func reconcileMirrors(online: Set<CGDirectDisplayID>) {
        for (id, request) in mirrors where request.committed && !isPending(id) {
            guard let record = records[id], let physical = record.mirroredPhysicalDisplayID else { continue }
            if online.contains(physical), CGDisplayMirrorsDisplay(physical) == record.handle.displayID,
               DisplayTopology.uuid(physical).map({ $0 == request.physicalUUID }) != false { continue }
            records[id]?.mirroredPhysicalDisplayID = nil
            records[id]?.mirroredPhysicalDisplayName = nil
            mirrors.removeValue(forKey: id)
        }
    }

    /// Creates a standalone HiDPI virtual display from a preset.
    @discardableResult
    func createVirtualDisplay(
        name: String,
        preset: VirtualDisplayPreset,
        onChange: @escaping () -> Void
    ) -> ManagedVirtualDisplayInfo? {
        let maxPx = preset.maxPixels
        let modeSpecs = preset.logicalModes.map {
            LDVirtualDisplayModeSpec(width: UInt($0.width), height: UInt($0.height), refreshRate: $0.hz)
        }
        return createVirtualDisplay(
            name: name,
            maxWidth: maxPx.width,
            maxHeight: maxPx.height,
            sizeInMM: preset.sizeInMM,
            modeSpecs: modeSpecs,
            mirroredPhysicalID: nil,
            mirroredPhysicalName: nil,
            onChange: onChange
        )
    }

    /// Creates a HiDPI virtual display tailored to a physical display's aspect ratio & orientation,
    /// then mirrors the physical display onto it so macOS renders crisp 2x HiDPI.
    func enableHiDPIMirror(
        for physicalDisplay: DisplayItem,
        onComplete: @escaping (Bool, String?) -> Void
    ) {
        if let record = mirrorRecord(forPhysicalDisplayID: physicalDisplay.id) {
            let active = !isPending(record.id) && CGDisplayMirrorsDisplay(physicalDisplay.id) == record.displayID
            onComplete(active, active ? nil : L("이미 가상 HiDPI 연결이 진행 중입니다.", "A virtual HiDPI connection is already in progress."))
            return
        }

        let isPortrait = physicalDisplay.isPortrait
        let physicalID = physicalDisplay.id
        guard let identity = DisplayTopology.uuid(physicalID), identity == physicalDisplay.uuidString,
              let online = DisplayTopology.onlineIDs(), online.contains(physicalID) else {
            onComplete(false, L("디스플레이 연결 상태가 변경되어 취소되었습니다.", "Cancelled because the display connection changed."))
            return
        }
        if online.contains(where: { CGDisplayMirrorsDisplay($0) == physicalID }) {
            onComplete(false, L("다른 화면이 이 디스플레이를 미러링 중이어서 적용할 수 없습니다.", "Another display is mirroring this one, so it cannot be applied."))
            return
        }
        guard physicalDisplay.logicalWidth > 0, physicalDisplay.logicalHeight > 0 else {
            onComplete(false, L("현재 화면 해상도 정보를 확인할 수 없습니다.", "Could not read the current display resolution."))
            return
        }
        let previous = CGDisplayMirrorsDisplay(physicalID)
        let previousUUID = previous == 0 ? nil : DisplayTopology.uuid(previous)
        guard previous == 0 || previousUUID != nil else {
            onComplete(false, L("기존 미러링 구성을 확인할 수 없어 안전하게 중단했습니다.", "Could not read the existing mirroring setup, so it was stopped to be safe."))
            return
        }
        let (baseW, baseH) = Self.mirrorBaseSize(width: physicalDisplay.logicalWidth,
                                                 height: physicalDisplay.logicalHeight)
        let hz = physicalDisplay.refreshRate > 0 ? physicalDisplay.refreshRate : 60

        let maxWidth = min(baseW * 2, isPortrait ? 2880 : 5120)
        let maxHeight = min(baseH * 2, isPortrait ? 5120 : 2880)

        let aspect = Double(baseW) / Double(baseH)
        let logicalModes = buildMatchedLogicalModes(
            baseWidth: baseW,
            baseHeight: baseH,
            aspect: aspect,
            hz: hz
        )

        let modeSpecs = logicalModes.map {
            LDVirtualDisplayModeSpec(width: UInt($0.0), height: UInt($0.1), refreshRate: $0.2)
        }

        let sizeInMM = isPortrait ? CGSize(width: 340, height: 600) : CGSize(width: 600, height: 340)
        let name = "\(physicalDisplay.name) HiDPI"

        guard let created = createVirtualDisplay(
            name: name,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            sizeInMM: sizeInMM,
            modeSpecs: modeSpecs,
            mirroredPhysicalID: physicalDisplay.id,
            mirroredPhysicalName: physicalDisplay.name,
            onChange: {}
        ) else {
            onComplete(false, L("가상 디스플레이 생성에 실패했습니다.", "Could not create the virtual display."))
            return
        }

        mirrors[created.id] = MirrorRequest(physicalUUID: identity, previousMaster: previous,
                                            previousMasterUUID: previousUUID, completion: onComplete)
        // Succeeds as soon as the mirror settles; the budget only bounds slow display reconfigurations.
        awaitMirror(id: created.id, modes: modeSpecs, attempts: 50)
    }

    /// Fits the physical logical size into a 2560×1440 box (1440×2560 in portrait), keeping the aspect ratio.
    /// Both sides are even so the 2× framebuffer and every derived mode stay on whole pixel pairs.
    nonisolated static func mirrorBaseSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let w = Double(width), h = Double(height)
        let portrait = height > width
        let fit = min(1, (portrait ? 1440 : 2560) / w, (portrait ? 2560 : 1440) / h)
        func even(_ value: Double) -> Int { max(2, Int((value / 2).rounded()) * 2) }
        return (even(w * fit), even(h * fit))
    }

    private func awaitMirror(id: UUID, modes: [LDVirtualDisplayModeSpec], attempts: Int) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, let record = self.records[id], let physical = record.mirroredPhysicalDisplayID,
                  var request = self.mirrors[id] else { return }
            let virtual = record.handle.displayID
            guard DisplayTopology.uuid(physical) == request.physicalUUID, CGDisplayIsOnline(physical) != 0 else {
                self.failMirror(id, reason: L("연결 대기 중 모니터 상태가 바뀌어 취소되었습니다.", "Cancelled because the monitor changed while connecting."))
                return
            }
            if CGDisplayIsOnline(virtual) != 0 && !request.committed,
               self.prepareVirtualMode(for: virtual, matching: modes) {
                guard CGDisplayMirrorsDisplay(physical) == request.previousMaster,
                      request.previousMaster == 0 || DisplayTopology.uuid(request.previousMaster) == request.previousMasterUUID,
                      LDMirrorDisplay(physical, virtual) else {
                    self.failMirror(id, reason: L("macOS 미러링 구성 적용에 실패했습니다.", "macOS could not apply the mirroring setup."))
                    return
                }
                request.committed = true
                self.mirrors[id] = request
            }
            if request.committed, CGDisplayMirrorsDisplay(physical) == virtual,
               let actual = CGDisplayCopyDisplayMode(virtual),
               self.matches(actual, specs: modes) {
                self.pending.removeValue(forKey: id)
                self.finishMirror(id, success: true, reason: nil)
            } else if attempts > 1 {
                self.awaitMirror(id: id, modes: modes, attempts: attempts - 1)
            } else {
                self.failMirror(id, reason: L("가상 HiDPI 모드가 제한 시간 안에 활성화되지 않았습니다.", "The virtual HiDPI mode did not become active in time."))
            }
        }
        pending[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func finishMirror(_ id: UUID, success: Bool, reason: String?) {
        let completion = mirrors[id]?.completion
        mirrors[id]?.completion = nil
        completion?(success, reason)
    }

    private func failMirror(_ id: UUID, reason: String) {
        let completion = mirrors[id]?.completion
        mirrors[id]?.completion = nil
        let removed = removeVirtualDisplay(id: id)
        completion?(false, removed ? reason : L("기존 미러 구성을 복원하지 못했습니다. 미러링 해제를 다시 시도하세요.", "Could not restore the previous mirroring setup. Try turning mirroring off again."))
    }

    private func matches(_ mode: CGDisplayMode, specs: [LDVirtualDisplayModeSpec]) -> Bool {
        mode.pixelWidth == 2 * mode.width && mode.pixelHeight == 2 * mode.height &&
            specs.contains { $0.width == mode.width && $0.height == mode.height &&
                abs($0.refreshRate - mode.refreshRate) < 0.01 }
    }

    private func prepareVirtualMode(for id: CGDirectDisplayID, matching specs: [LDVirtualDisplayModeSpec]) -> Bool {
        if let current = CGDisplayCopyDisplayMode(id), matches(current, specs: specs) { return true }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] else { return false }
        for spec in specs {
            if let mode = modes.first(where: { matches($0, specs: [spec]) }) {
                return CGDisplaySetDisplayMode(id, mode, nil) == .success
            }
        }
        return false
    }

    func isPending(_ id: UUID) -> Bool { pending[id] != nil }

    @discardableResult
    func removeVirtualDisplay(id: UUID) -> Bool {
        guard let record = records[id] else { return true }
        pending.removeValue(forKey: id)?.cancel()
        if let request = mirrors[id], request.committed, let physical = record.mirroredPhysicalDisplayID,
           DisplayTopology.uuid(physical) == request.physicalUUID,
           CGDisplayMirrorsDisplay(physical) == record.handle.displayID {
            var restore = kCGNullDirectDisplay
            if let uuid = request.previousMasterUUID {
                guard let online = DisplayTopology.onlineIDs() else { return false }
                restore = online.first { DisplayTopology.uuid($0) == uuid } ?? kCGNullDirectDisplay
            }
            guard LDMirrorDisplay(physical, restore) else { return false }
        }
        mirrors.removeValue(forKey: id)
        records.removeValue(forKey: id)
        record.handle.invalidate()
        return true
    }

    func cancelPending() {
        for id in Array(pending.keys) { removeVirtualDisplay(id: id) }
    }

    func removeAll() {
        for id in Array(records.keys) where !removeVirtualDisplay(id: id) {
            NSLog("halo: failed to restore mirroring for virtual display %@", id.uuidString)
        }
    }

    // MARK: - Internal Helpers

    private func createVirtualDisplay(
        name: String,
        maxWidth: Int,
        maxHeight: Int,
        sizeInMM: CGSize,
        modeSpecs: [LDVirtualDisplayModeSpec],
        mirroredPhysicalID: CGDirectDisplayID?,
        mirroredPhysicalName: String?,
        onChange: @escaping () -> Void
    ) -> ManagedVirtualDisplayInfo? {
        let id = UUID()
        let serial = nextSerial
        nextSerial += 1

        guard let handle = LDVirtualDisplayHandle(
            name: name,
            maxWidth: UInt(maxWidth),
            maxHeight: UInt(maxHeight),
            sizeInMillimeters: sizeInMM,
            modes: modeSpecs,
            hiDPI: true,
            serialNumber: serial,
            terminationHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, self.records.removeValue(forKey: id) != nil else { return }
                    self.pending.removeValue(forKey: id)?.cancel()
                    let request = self.mirrors.removeValue(forKey: id)
                    request?.completion?(false, L("가상 디스플레이가 시스템에 의해 종료되었습니다.", "The system closed the virtual display."))
                    onChange()
                }
            }
        ) else {
            return nil
        }

        let record = ActiveRecord(
            id: id,
            handle: handle,
            name: name,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            mirroredPhysicalDisplayID: mirroredPhysicalID,
            mirroredPhysicalDisplayName: mirroredPhysicalName
        )
        records[id] = record

        return ManagedVirtualDisplayInfo(
            id: id,
            displayID: handle.displayID,
            name: name,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            mirroredPhysicalDisplayID: mirroredPhysicalID,
            mirroredPhysicalDisplayName: mirroredPhysicalName
        )
    }

    private func buildMatchedLogicalModes(
        baseWidth: Int,
        baseHeight: Int,
        aspect: Double,
        hz: Double
    ) -> [(Int, Int, Double)] {
        var candidates: [(Int, Int)] = [(baseWidth, baseHeight)]

        // Provide crisp stepped logical HiDPI sizes matching the physical display aspect ratio
        let scales: [Double] = [0.9, 0.85, 0.8, 0.75, 0.67]
        for s in scales {
            let w = (Int((Double(baseWidth) * s).rounded()) / 2) * 2
            let h = (Int((Double(w) / aspect).rounded()) / 2) * 2
            if w >= 640 && h >= 480 {
                candidates.append((w, h))
            }
        }

        var seen = Set<String>()
        var result: [(Int, Int, Double)] = []
        for (w, h) in candidates {
            let key = "\(w)x\(h)"
            if seen.insert(key).inserted {
                result.append((w, h, hz))
                if abs(hz - 60.0) > 1.0 {
                    result.append((w, h, 60.0))
                }
            }
        }
        return result
    }
}
