import Foundation
import CoreGraphics
import CDisplayBridge

struct DDCReading {
    let result: LDVCPReadResult
    let current: UInt16
    let maximum: UInt16

    var fraction: Double? {
        guard result == .valid, maximum > 0 else { return nil }
        return Double(current) / Double(maximum)
    }

    var description: String {
        switch result {
        case .valid: return "확인됨 (\(current)/\(maximum))"
        case .unsupported: return "VCP 미지원"
        case .invalidReply: return "유효하지 않은 응답"
        default: return "전송 오류"
        }
    }

    init(service: CFTypeRef, profile: inout UInt8) {
        var value: UInt16 = 0, maxValue: UInt16 = 0
        result = LDDDCReadVCP(service, 0x10, &value, &maxValue, &profile)
        current = value
        maximum = maxValue
    }
}

/// Main-thread requests, one serial I/O queue per physical port across topology generations.
/// Uses coalescing throttle for writes so holding brightness keys updates hardware smoothly in real time.
final class DDCChannel {
    enum WriteResult {
        case failed
        case sent
        case readback(DDCReading)
    }

    let port: String
    let uuid: String
    private let id: CGDirectDisplayID
    private let queue: DispatchQueue
    private var service: CFTypeRef? // Access exclusively on queue.
    private var readProfile: UInt8 = 0 // Access exclusively on queue.
    private var probeWork: DispatchWorkItem?
    private var writeWork: DispatchWorkItem?
    private var verifyWork: DispatchWorkItem?

    private var pendingWrite: (value: UInt16, verify: Bool, version: Int, completion: (WriteResult) -> Void)?
    private(set) var revision = 0

    init(id: CGDirectDisplayID, uuid: String, port: String, queue: DispatchQueue) {
        self.id = id
        self.uuid = uuid
        self.port = port
        self.queue = queue
    }

    func probe(_ completion: @escaping (DDCReading?) -> Void) {
        probeWork?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, DisplayTopology.uuid(id) == uuid else { return }
            if service == nil { service = LDCreateAVServiceForPort(port) }
            let reading = service.map { DDCReading(service: $0, profile: &self.readProfile) }
            DispatchQueue.main.async { completion(reading) }
        }
        probeWork = task
        queue.async(execute: task)
    }

    func cancelWrites() {
        revision += 1
        pendingWrite = nil
        writeWork?.cancel()
        verifyWork?.cancel()
        writeWork = nil
        verifyWork = nil
    }

    func write(_ value: UInt16, verify: Bool, completion: @escaping (WriteResult) -> Void) {
        revision += 1
        let version = revision
        verifyWork?.cancel()
        verifyWork = nil
        pendingWrite = (value, verify, version, completion)

        // Coalesce rapid repeats without starving writes while a key is held down.
        guard writeWork == nil else { return }
        scheduleNextWriteFlush()
    }

    private func scheduleNextWriteFlush() {
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.writeWork = nil
            guard let request = self.pendingWrite else { return }
            self.pendingWrite = nil

            self.queue.async { [weak self] in
                guard let self else { return }
                if self.service == nil, DisplayTopology.uuid(self.id) == self.uuid {
                    self.service = LDCreateAVServiceForPort(self.port)
                }
                let ok = DisplayTopology.uuid(self.id) == self.uuid &&
                    self.service.map { LDDDCWriteVCP($0, 0x10, request.value) } == true

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    // If newer input arrived while writing, flush it next; report result if still latest.
                    if self.pendingWrite != nil && self.writeWork == nil {
                        self.scheduleNextWriteFlush()
                    }
                    guard self.revision == request.version else { return }
                    request.completion(ok ? .sent : .failed)
                    if ok && request.verify && self.revision == request.version {
                        self.scheduleVerification(request.version, completion: request.completion)
                    }
                }
            }
        }
        writeWork = task
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30), execute: task)
    }

    private func scheduleVerification(_ version: Int, completion: @escaping (WriteResult) -> Void) {
        let task = DispatchWorkItem { [weak self] in
            guard let self, DisplayTopology.uuid(id) == uuid, let service else { return }
            let reading = DDCReading(service: service, profile: &self.readProfile)
            DispatchQueue.main.async {
                if self.revision == version { completion(.readback(reading)) }
            }
        }
        verifyWork = task
        queue.asyncAfter(deadline: .now() + .milliseconds(250), execute: task)
    }

    func invalidate() {
        probeWork?.cancel()
        cancelWrites()
    }
}
