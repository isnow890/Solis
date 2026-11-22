// Run on a logged-in Mac: swift Tests/Smoke/FirstLaunch.swift /path/to/halo.app
import AppKit
import ApplicationServices

struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw Failure("Command failed: \(executable)") }
}

func waitUntil(seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
    let end = ProcessInfo.processInfo.systemUptime + seconds
    repeat {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    } while ProcessInfo.processInfo.systemUptime < end
    return condition()
}

func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(node, name as CFString, &value)
    return value
}

func laterButton(in node: AXUIElement) -> AXUIElement? {
    if attribute(node, "AXRole") as? String == "AXButton",
       attribute(node, "AXTitle") as? String == "나중에" { return node }
    for child in attribute(node, "AXChildren") as? [AXUIElement] ?? [] {
        if let match = laterButton(in: child) { return match }
    }
    return nil
}

func checkFirstLaunch(of source: URL) throws {
    guard AXIsProcessTrusted() else { throw Failure("Run from a terminal with Accessibility access to click the test app’s Later button.") }
    let files = FileManager.default
    let session = UUID().uuidString
    let folder = files.temporaryDirectory.appendingPathComponent("halo-smoke-\(session)")
    try files.createDirectory(at: folder, withIntermediateDirectories: false)
    let id = "com.isnow890.halo.smoke.\(session)"
    let bundle = folder.appendingPathComponent("halo.app")
    let defaults = UserDefaults(suiteName: id)!
    func runningApp() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: id).first
    }
    defer {
        if let app = runningApp() {
            app.terminate()
            if !waitUntil(seconds: 3, { app.isTerminated }) { app.forceTerminate() }
        }
        defaults.removePersistentDomain(forName: id)
        try? files.removeItem(at: folder)
    }
    try files.copyItem(at: source, to: bundle)
    try run("/usr/bin/plutil", ["-replace", "CFBundleIdentifier", "-string", id, bundle.appendingPathComponent("Contents/Info.plist").path])
    try run("/usr/bin/codesign", ["--force", "--sign", "-", bundle.path])
    defaults.set(false, forKey: "halo.updates.automatic")

    func launch() throws -> NSRunningApplication {
        try run("/usr/bin/open", [bundle.path])
        guard waitUntil(seconds: 10, { runningApp()?.isFinishedLaunching == true }), let app = runningApp() else {
            throw Failure("Test app did not finish launching")
        }
        return app
    }
    let first = try launch()
    let root = AXUIElementCreateApplication(first.processIdentifier)
    guard waitUntil(seconds: 10, { laterButton(in: root) != nil }),
          let later = laterButton(in: root),
          AXUIElementPerformAction(later, kAXPressAction as CFString) == .success,
          waitUntil(seconds: 3, { laterButton(in: root) == nil && !first.isTerminated }) else {
        throw Failure("The first-launch guide did not open and dismiss with Later")
    }
    first.terminate()
    guard waitUntil(seconds: 5, { first.isTerminated }) else { throw Failure("Test app did not quit") }
    let second = try launch()
    let relaunched = AXUIElementCreateApplication(second.processIdentifier)
    if waitUntil(seconds: 3, { second.isTerminated || laterButton(in: relaunched) != nil }) {
        throw Failure("The app quit or the permission guide reopened on the second launch")
    }
}

do {
    guard CommandLine.arguments.count == 2 else { throw Failure("Pass the path to a built halo.app") }
    try checkFirstLaunch(of: URL(fileURLWithPath: CommandLine.arguments[1]))
    print("Passed: first launch, Later, and relaunch")
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
