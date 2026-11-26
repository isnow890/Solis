import Foundation
import Combine

/// Bundle versions may omit trailing zeroes. Numeric components are compared without integer overflow.
struct ReleaseVersion: Comparable {
    private let core: [Substring]
    private let prerelease: [Substring]

    init?(_ tag: String) {
        let value = tag.first == "v" ? tag.dropFirst() : tag[...]
        let parts = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        guard let version = parts.first else { return nil }
        let base = version.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let number = base.first else { return nil }
        var fields = number.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(fields.count), fields.allSatisfy(Self.validNumber) else { return nil }
        while fields.count < 3 { fields.append("0") }
        core = fields
        prerelease = base.dropFirst().flatMap { $0.split(separator: ".", omittingEmptySubsequences: false) }
        let metadata = parts.dropFirst().flatMap { $0.split(separator: ".", omittingEmptySubsequences: false) }
        for identifier in prerelease + metadata {
            guard !identifier.isEmpty, identifier.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
            }) else { return nil }
        }
        guard prerelease.allSatisfy({ !Self.isNumeric($0) || Self.validNumber($0) }) else { return nil }
    }

    private static func isNumeric(_ value: Substring) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func validNumber(_ value: Substring) -> Bool {
        isNumeric(value) && (value.count == 1 || value.first != "0")
    }

    private static func numericLess(_ lhs: Substring, _ rhs: Substring) -> Bool {
        lhs.count == rhs.count ? lhs < rhs : lhs.count < rhs.count
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for (a, b) in zip(lhs.core, rhs.core) where a != b { return numericLess(a, b) }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
        }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            let aNumeric = isNumeric(a), bNumeric = isNumeric(b)
            if aNumeric && bNumeric { return numericLess(a, b) }
            if aNumeric != bNumeric { return aNumeric }
            return a < b
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    struct Release {
        let tag: String
        var version: String { tag.first == "v" ? String(tag.dropFirst()) : tag }
        var url: URL { URL(string: "https://github.com/isnow890/halo/releases/tag/")!.appendingPathComponent(tag) }
    }

    private struct Payload: Decodable { let tag_name: String }
    private enum Key {
        static let automatic = "halo.updates.automatic"
        static let lastCheck = "halo.updates.lastCheck"
        static let cachedTag = "halo.updates.latestTag"
        static let skippedTag = "halo.updates.skippedTag"
    }

    @Published var automaticallyChecks: Bool {
        didSet {
            defaults.set(automaticallyChecks, forKey: Key.automatic)
            if !automaticallyChecks && !manualRequested {
                task?.cancel()
                task = nil
                checking = false
            }
            schedule()
        }
    }
    @Published private(set) var available: Release?
    @Published private(set) var checking = false
    @Published var manualMessage: String?

    private let defaults: UserDefaults
    private let session: URLSession
    private let installed: ReleaseVersion?
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var manualRequested = false
    private var running = false

    init(defaults: UserDefaults = .standard, session: URLSession? = nil,
         bundleVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) {
        self.defaults = defaults
        installed = bundleVersion.flatMap(ReleaseVersion.init)
        automaticallyChecks = defaults.object(forKey: Key.automatic) as? Bool ?? true
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        self.session = session ?? URLSession(configuration: config)
    }

    func start() {
        guard !running else { return }
        running = true
        if let tag = defaults.string(forKey: Key.cachedTag), let version = ReleaseVersion(tag) {
            present(tag, version: version)
        }
        schedule()
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
        manualRequested = false
        checking = false
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard running, automaticallyChecks, installed != nil, task == nil else { return }
        let now = Date()
        if let last = defaults.object(forKey: Key.lastCheck) as? Date, last <= now {
            let due = last.addingTimeInterval(24 * 60 * 60)
            if due > now {
                let next = Timer(fire: due, interval: 0, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.schedule() }
                }
                RunLoop.main.add(next, forMode: .common)
                timer = next
                return
            }
        }
        check()
    }

    func checkManually() {
        guard running else { return }
        guard installed != nil else {
            manualMessage = L("앱 번들의 버전 정보를 읽을 수 없습니다.", "Could not read the version from the app bundle.")
            return
        }
        manualMessage = nil
        manualRequested = true
        if task == nil { check() }
    }

    private func check() {
        timer?.invalidate()
        timer = nil
        checking = true
        defaults.set(Date(), forKey: Key.lastCheck)
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/isnow890/halo/releases/latest")!)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("halo", forHTTPHeaderField: "User-Agent")
        task = Task {
            do {
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                switch (response as? HTTPURLResponse)?.statusCode {
                case 404:
                    available = nil
                    defaults.removeObject(forKey: Key.cachedTag)
                    if manualRequested { manualMessage = L("공개된 halo 릴리즈를 찾지 못했습니다.", "No published halo release was found.") }
                case 200:
                    let tag = try JSONDecoder().decode(Payload.self, from: data).tag_name
                    guard let version = ReleaseVersion(tag) else { throw URLError(.cannotParseResponse) }
                    defaults.set(tag, forKey: Key.cachedTag)
                    present(tag, version: version)
                    if manualRequested && available == nil { manualMessage = L("현재 최신 버전을 사용 중입니다.", "You are on the latest version.") }
                default:
                    throw URLError(.badServerResponse)
                }
            } catch {
                guard !Task.isCancelled else { return }
                if manualRequested { manualMessage = L("업데이트를 확인하지 못했습니다. 잠시 후 다시 시도하세요.", "Could not check for updates. Please try again later.") }
            }
            manualRequested = false
            checking = false
            task = nil
            schedule()
        }
    }

    private func present(_ tag: String, version: ReleaseVersion) {
        let skipped = defaults.string(forKey: Key.skippedTag).flatMap(ReleaseVersion.init)
        if let installed, version > installed, manualRequested || skipped != version {
            available = Release(tag: tag)
        } else {
            available = nil
        }
    }

    func dismissForSession() {
        available = nil
    }

    func skip() {
        guard let available else { return }
        defaults.set(available.tag, forKey: Key.skippedTag)
        self.available = nil
    }
}
