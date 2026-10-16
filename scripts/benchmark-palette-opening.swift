// Run with xcrun swift scripts/benchmark-palette-opening.swift [rounds]
// Measures global shortcut dispatch to a nontransparent onscreen palette window
// The 2 ms WindowServer polling interval is not a measurement of first displayed pixels
import AppKit
import CoreGraphics

let apps = ["Kit", "Raycast"]
guard CGPreflightPostEventAccess() else {
    fputs("System shortcut measurement requires existing event posting access\n", stderr)
    exit(1)
}
let cycles = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 10
guard (1...100).contains(cycles) else {
    fputs("Choose between 1 and 100 rounds\n", stderr)
    exit(1)
}
var processIDs: [String: pid_t] = [:]
for name in apps {
    guard let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.executableURL?.lastPathComponent == name
    }) else {
        fputs("Both Kit and Raycast must be running\n", stderr)
        exit(1)
    }
    processIDs[name] = app.processIdentifier
}
var index = 0
var deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
var openedAt: UInt64?
var hasResult = false
var closing = false
var closeStartedAt: UInt64?
func press(_ code: CGKeyCode, option: Bool = false) {
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)!
        event.flags = option ? .maskAlternate : []
        event.post(tap: .cghidEventTap)
    }
}
func visible(_ name: String) -> Bool {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.contains { window in
        guard window[kCGWindowOwnerPID as String] as? pid_t == processIDs[name],
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let width = bounds["Width"] as? Double,
              let height = bounds["Height"] as? Double else { return false }
        return width > 400 && height > 300 && (window[kCGWindowAlpha as String] as? Double ?? 0) > 0
    }
}
print("app,round,window_ms")
press(53)
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now(), repeating: .milliseconds(2))
timer.setEventHandler {
    let now = DispatchTime.now().uptimeNanoseconds
    guard now >= deadline else { return }
    if index >= cycles * 2 { exit(0) }
    let name = apps[index % 2]
    if closing {
        if visible(name) {
            closeStartedAt = closeStartedAt ?? now
            guard now - closeStartedAt! < 3_000_000_000 else {
                fputs("Close other Kit and Raycast windows before benchmarking\n", stderr)
                exit(1)
            }
            press(53)
            deadline = now + 200_000_000
            return
        }
        closeStartedAt = nil
        closing = false
        if hasResult { index += 1 }
        hasResult = false
        deadline = now + 500_000_000
        return
    }
    if let start = openedAt {
        if visible(name) {
            let observedAt = DispatchTime.now().uptimeNanoseconds
            print("\(name),\(index / 2),\(String(format: "%.2f", Double(observedAt-start)/1_000_000))")
            fflush(stdout)
            openedAt = nil
            hasResult = true
            closing = true
            deadline = now + 500_000_000
        } else if now - start > 3_000_000_000 {
            print("\(name),\(index / 2),timeout")
            fflush(stdout)
            openedAt = nil
            hasResult = true
            closing = true
        }
    } else {
        if visible(name) {
            closing = true
            closeStartedAt = now
            return
        }
        openedAt = DispatchTime.now().uptimeNanoseconds
        press(name == "Kit" ? 13 : 8, option: true)
    }
}
timer.resume()
RunLoop.main.run()
