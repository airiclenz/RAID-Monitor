// notify-helper.swift — RAID Monitor notification helper
// Compiled once during installation; called by raid-monitor.sh.
//
// Usage:
//   raid-monitor-notify --title <t> --subtitle <s> --body <b> --level info|warning|critical
//
// Exit codes:
//   0  notification posted
//   1  bad arguments or authorisation denied
//   2  posting error
//   3  timed out waiting for delivery
//
// Compile and sign:
//   swiftc notify-helper.swift -o raid-monitor-notify
//   codesign --sign - --identifier "com.airic-lenz.raid-monitor" raid-monitor-notify

import Foundation
import UserNotifications

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

var title: String    = ""
var subtitle: String = ""
var body: String     = ""
var level: String    = "warning"

let argv = CommandLine.arguments
var i = 1
while i < argv.count {
    let flag = argv[i]
    let next = (i + 1 < argv.count) ? argv[i + 1] : nil

    switch flag {
    case "--title":
        guard let v = next else { fputs("Missing value for --title\n", stderr); exit(1) }
        title = v; i += 2
    case "--subtitle":
        guard let v = next else { fputs("Missing value for --subtitle\n", stderr); exit(1) }
        subtitle = v; i += 2
    case "--body":
        guard let v = next else { fputs("Missing value for --body\n", stderr); exit(1) }
        body = v; i += 2
    case "--level":
        guard let v = next else { fputs("Missing value for --level\n", stderr); exit(1) }
        level = v; i += 2
    default:
        fputs("Unknown argument: \(flag)\n", stderr)
        fputs("Usage: raid-monitor-notify --title <t> --subtitle <s> --body <b> --level info|warning|critical\n", stderr)
        exit(1)
    }
}

if title.isEmpty || body.isEmpty {
    fputs("Error: --title and --body are required.\n", stderr)
    fputs("Usage: raid-monitor-notify --title <t> --subtitle <s> --body <b> --level info|warning|critical\n", stderr)
    exit(1)
}

// ---------------------------------------------------------------------------
// Build notification content
// ---------------------------------------------------------------------------

let content = UNMutableNotificationContent()
content.title = title
if !subtitle.isEmpty { content.subtitle = subtitle }
content.body = body
content.categoryIdentifier = "com.airic-lenz.raid-monitor"

if #available(macOS 12.0, *) {
    switch level {
    case "critical":
        content.interruptionLevel = .timeSensitive
        content.sound = UNNotificationSound.default
    case "info":
        content.interruptionLevel = .active
        // No sound for informational alerts (e.g. rebuild started)
    default: // "warning"
        content.interruptionLevel = .active
        content.sound = UNNotificationSound.default
    }
} else {
    if level == "warning" || level == "critical" {
        content.sound = UNNotificationSound.default
    }
}

// ---------------------------------------------------------------------------
// Request authorisation and post
// ---------------------------------------------------------------------------

let semaphore = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0

let center = UNUserNotificationCenter.current()

center.requestAuthorization(options: [.alert, .sound]) { granted, authError in
    if let authError = authError {
        fputs("raid-monitor-notify: authorisation error: \(authError.localizedDescription)\n", stderr)
        exitCode = 1
        semaphore.signal()
        return
    }
    guard granted else {
        fputs("raid-monitor-notify: permission denied.\n", stderr)
        fputs("  Open System Settings → Notifications → raid-monitor-notify → Allow Notifications\n", stderr)
        exitCode = 1
        semaphore.signal()
        return
    }

    // Attach the bundled icon image so it appears as a thumbnail in the
    // notification banner. This is more reliable than the app-icon corner
    // rendering, which can show a white square for ad-hoc signed bundles.
    if let iconURL = Bundle.main.url(forResource: "notification-icon", withExtension: "png"),
       let attachment = try? UNNotificationAttachment(identifier: "icon", url: iconURL, options: nil) {
        content.attachments = [attachment]
    }

    let identifier = "com.airic-lenz.raid-monitor.\(Int(Date().timeIntervalSince1970))"
    let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)

    center.add(request) { postError in
        if let postError = postError {
            fputs("raid-monitor-notify: error posting notification: \(postError.localizedDescription)\n", stderr)
            exitCode = 2
        }
        semaphore.signal()
    }
}

// Block until the callback fires, pumping the run loop so framework callbacks
// can execute. A 10-second timeout guards against unexpected hangs.
let deadline = Date(timeIntervalSinceNow: 10.0)
while semaphore.wait(timeout: .now()) == .timedOut {
    if Date() >= deadline {
        fputs("raid-monitor-notify: timed out waiting for notification delivery\n", stderr)
        exitCode = 3
        break
    }
    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
}

exit(exitCode)
