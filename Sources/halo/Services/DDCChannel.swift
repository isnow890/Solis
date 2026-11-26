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
        case .valid: return L("확인됨 (\(current)/\(maximum))", "verified (\(current)/\(maximum))")
        case .unsupported: return L("VCP 미지원", "VCP not supported")
        case .invalidReply: return L("유효하지 않은 응답", "invalid reply")
        default: return L("전송 오류", "transfer error")
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
        case readback(DDCReading?)
    }

    let port: String
    let uuid: String
    private let id: CGDirectDisplayID
    private let queue: DispatchQueue
    private var service: CFTypeRef? // Access exclusively on queue.
    private var readProfile: UInt8 = 0 // Access exclusively on queue.
    private var probeWork: DispatchWorkItem?
    private var verifyWork: DispatchWorkItem?

    // The port queue takes the latest request only when it is actually ready for I/O.
    // The lock covers the mailbox and its cancellation generation, never a hardware call.
    private let mailbox = NSLock()
    private var epoch = 0
    private typealias PendingWrite = (value: UInt16, verify: Bool, version: Int, completion: (WriteResult) -> Void)
    private var pendingWrite: PendingWrite?
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
        mailbox.withLock {
            epoch += 1
            pendingWrite = nil
        }
        verifyWork?.cancel()
        verifyWork = nil
    }

    func write(_ value: UInt16, verify: Bool, completion: @escaping (WriteResult) -> Void) {
        revision += 1
        let version = revision
        verifyWork?.cancel()
        verifyWork = nil
        let scheduledEpoch: Int? = mailbox.withLock {
            let needsFlush = pendingWrite == nil
            pendingWrite = (value, verify, version, completion)
            return needsFlush ? epoch : nil
        }
        guard let scheduledEpoch else { return }
        queue.asyncAfter(deadline: .now() + .milliseconds(30)) { [weak self] in
            self?.flush(epoch: scheduledEpoch)
        }
    }

    private func flush(epoch scheduledEpoch: Int) {
        let request: PendingWrite? = mailbox.withLock {
            guard epoch == scheduledEpoch else { return nil }
            defer { pendingWrite = nil }
            return pendingWrite
        }
        guard let request else { return }
        let ok: Bool
        if DisplayTopology.uuid(id) == uuid {
            if service == nil { service = LDCreateAVServiceForPort(port) }
            ok = service.map { LDDDCWriteVCP($0, 0x10, request.value) } == true
        } else {
            ok = false
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, revision == request.version else { return }
            request.completion(ok ? .sent : .failed)
            if ok && request.verify && revision == request.version {
                scheduleVerification(request.version, completion: request.completion)
            }
        }
    }

    private func scheduleVerification(_ version: Int, completion: @escaping (WriteResult) -> Void) {
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let reading = DisplayTopology.uuid(id) == uuid ? service.map { DDCReading(service: $0, profile: &self.readProfile) } : nil
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
