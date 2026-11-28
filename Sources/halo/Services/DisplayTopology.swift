import AppKit
import CoreGraphics

enum DisplayTopology {
    static func onlineIDs() -> [CGDirectDisplayID]? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
        if count == 0 { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        return Array(ids.prefix(Int(count)))
    }

    static func uuid(_ id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func desktopID(_ id: CGDirectDisplayID) -> CGDirectDisplayID {
        let master = CGDisplayMirrorsDisplay(id)
        return master == kCGNullDirectDisplay ? id : master
    }

    static func screenID(_ screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        let desktop = desktopID(id)
        return NSScreen.screens.first { screenID($0) == desktop } ??
            NSScreen.screens.first { screenID($0).map(desktopID) == desktop }
    }

    /// Asks the window server where the cursor is right now. `NSEvent.mouseLocation` can instead report the
    /// location carried by the event being handled, and media brightness keys may carry (0, 0), which always
    /// resolved to the main display.
    static func screenUnderMouse() -> CGDirectDisplayID? {
        if let point = CGEvent(source: nil)?.location {
            var id = kCGNullDirectDisplay
            var count: UInt32 = 0
            if CGGetDisplaysWithPoint(point, 1, &id, &count) == .success, count > 0 { return id }
        }
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }.flatMap(screenID)
    }
}
