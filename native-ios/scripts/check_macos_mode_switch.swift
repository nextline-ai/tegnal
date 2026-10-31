// Run after ./native-ios/scripts/build_and_run.sh --verify:
// swift native-ios/scripts/check_macos_mode_switch.swift <TEGNAL PID>
// Exercises real macOS wheel events; simulated iOS swipes do not cover this crash.
import AppKit
import ApplicationServices

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
require(CommandLine.arguments.count == 2, "Pass the PID of the development TEGNAL app.")
guard let pid = pid_t(CommandLine.arguments[1]),
      let app = NSRunningApplication(processIdentifier: pid) else { fputs("FAIL: App is not running\n", stderr); exit(1) }
require(app.bundleIdentifier == "work.nextline.tegnal", "PID must belong to TEGNAL.")
require(AXIsProcessTrusted(), "The invoking terminal needs Accessibility access.")
let previousApp = NSWorkspace.shared.frontmostApplication
let previousPoint = CGEvent(source: nil)?.location
let application = AXUIElementCreateApplication(pid)
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return value
}
func modeControl(in element: AXUIElement) -> AXUIElement? {
    if attribute(element, kAXIdentifierAttribute) as? String == "app.mode" { return element }
    for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if let found = modeControl(in: child) { return found }
    }
    return nil
}
func control() -> AXUIElement {
    for window in attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
        if let found = modeControl(in: window) { return found }
    }
    fputs("FAIL: Mode switch unavailable: open a root library tab and dismiss any sheets.\n", stderr); exit(1)
}
func selection() -> String { attribute(control(), kAXValueAttribute) as? String ?? "" }
func center() -> CGPoint {
    var point = CGPoint.zero, size = CGSize.zero
    let element = control()
    guard let position = attribute(element, kAXPositionAttribute),
          let dimensions = attribute(element, kAXSizeAttribute) else { fputs("FAIL: Missing control bounds\n", stderr); exit(1) }
    require(AXValueGetValue(position as! AXValue, .cgPoint, &point), "Missing position")
    require(AXValueGetValue(dimensions as! AXValue, .cgSize, &size), "Missing size")
    return CGPoint(x: point.x + size.width / 2, y: point.y + size.height / 2)
}
require(AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success,
        "Could not bring the development app to the foreground.")
RunLoop.current.run(until: Date().addingTimeInterval(2))
require(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, "TEGNAL must be in the foreground.")
let initial = selection()
require(!initial.isEmpty, "Mode switch must expose its selected mode.")
let started = Date()
var eventCount = 0
for _ in 0..<4 {
    let selected = selection(), point = center()
    CGWarpMouseCursorPosition(point)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(100_000)
    for units in [CGScrollEventUnit.line, .pixel] {
        for horizontal in [false, true] {
            for index in 0..<20 {
                let delta: Int32 = index.isMultiple(of: 2) ? 3 : -3
                let event = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2,
                                    wheel1: horizontal ? 0 : delta, wheel2: horizontal ? delta : 0, wheel3: 0)!
                event.location = point
                if units == .pixel {
                    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: index == 0 ? 1 : (index == 19 ? 4 : 2))
                }
                event.post(tap: .cghidEventTap)
                eventCount += 1
                usleep(15_000)
            }
        }
    }
    usleep(250_000)
    require(!app.isTerminated, "App terminated after scrolling over the mode switch.")
    require(selection() == selected, "Scrolling changed the library mode.")
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: center(), mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(50_000)
    }
    usleep(1_000_000)
    require(selection() != selected, "Click must still switch libraries (before: \(selected), after: \(selection())).")
}
require(selection() == initial, "Expected to restore the initial library mode.")
if let previousPoint { CGWarpMouseCursorPosition(previousPoint) }
previousApp?.activate()
// A debugger can leave the app alive after an Objective-C exception: also check logs.
let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
let log = Process(), output = Pipe()
log.executableURL = URL(fileURLWithPath: "/usr/bin/log")
log.arguments = ["show", "--start", formatter.string(from: started), "--style", "compact", "--predicate",
                 "processIdentifier == \(pid) AND (eventMessage CONTAINS 'UIScrollEvent' OR eventMessage CONTAINS 'Missing expected nonaccelerated scroll delta')"]
log.standardOutput = output; log.standardError = FileHandle.nullDevice
try log.run()
let messages = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
log.waitUntilExit()
require(log.terminationStatus == 0, "Could not inspect crash diagnostics.")
require(!messages.contains("UIScrollEvent") && !messages.contains("Missing expected nonaccelerated"), "Scroll assertion detected:\n\(messages)")
print("PASS: \(eventCount) wheel/trackpad events across both modes; four successful clicks; no scroll assertion.")
