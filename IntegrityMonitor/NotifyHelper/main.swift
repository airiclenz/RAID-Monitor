// notify-helper — RAID Integrity Monitor notification helper
// Compiled as part of the SPM build; installed into an app bundle by install.sh.
//
// Usage:
//   raid-integrity-monitor-notify --title <t> --subtitle <s> --body <b> --level info|warning|critical
//
// Exit codes:
//   0  notification posted
//   1  bad arguments or authorisation denied
//   2  posting error
//   3  timed out waiting for delivery

import Foundation
import AppKit
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
		guard let value = next else { fputs("Missing value for --title\n", stderr); exit(1) }
		title = value; i += 2
	case "--subtitle":
		guard let value = next else { fputs("Missing value for --subtitle\n", stderr); exit(1) }
		subtitle = value; i += 2
	case "--body":
		guard let value = next else { fputs("Missing value for --body\n", stderr); exit(1) }
		body = value; i += 2
	case "--level":
		guard let value = next else { fputs("Missing value for --level\n", stderr); exit(1) }
		level = value; i += 2
	default:
		fputs("Unknown argument: \(flag)\n", stderr)
		fputs("Usage: raid-integrity-monitor-notify --title <t> --subtitle <s> --body <b> --level info|warning|critical\n", stderr)
		exit(1)
	}
}

if title.isEmpty || body.isEmpty {
	fputs("Error: --title and --body are required.\n", stderr)
	fputs("Usage: raid-integrity-monitor-notify --title <t> --subtitle <s> --body <b> --level info|warning|critical\n", stderr)
	exit(1)
}

// ---------------------------------------------------------------------------
// NSApplication setup
//
// macOS 15+ requires a running NSApplication event loop for
// UNUserNotificationCenter to present banners on screen. Without it, the
// notification is accepted by usernoted (appears in Notification Centre list)
// but no desktop banner is shown. LSUIElement=true in Info.plist suppresses
// the Dock icon; .accessory policy here suppresses the App Switcher entry.
// ---------------------------------------------------------------------------

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// ---------------------------------------------------------------------------
// Build notification content
// ---------------------------------------------------------------------------

let content = UNMutableNotificationContent()
content.title = title
if !subtitle.isEmpty { content.subtitle = subtitle }
content.body = body
content.categoryIdentifier = "com.airic-lenz.raid-integrity-monitor"

if #available(macOS 12.0, *) {
	switch level {
	case "critical":
		content.interruptionLevel = .timeSensitive
		content.sound = UNNotificationSound.default
	case "info":
		content.interruptionLevel = .active
		// No sound for informational alerts
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

var exitCode: Int32 = 0

let center = UNUserNotificationCenter.current()

// Timeout: terminate the app after 10 seconds regardless of callback status.
DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
	fputs("raid-integrity-monitor-notify: timed out waiting for notification delivery\n", stderr)
	exitCode = 3
	NSApplication.shared.terminate(nil)
}

center.requestAuthorization(options: [.alert, .sound]) { granted, authError in
	if let authError = authError {
		fputs("raid-integrity-monitor-notify: authorisation error: \(authError.localizedDescription)\n", stderr)
		exitCode = 1
		DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
		return
	}
	guard granted else {
		fputs("raid-integrity-monitor-notify: permission denied.\n", stderr)
		fputs("  Open System Settings → Notifications → RAID Integrity Monitor → Allow Notifications\n", stderr)
		exitCode = 1
		DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
		return
	}

	let identifier = "com.airic-lenz.raid-integrity-monitor.\(Int(Date().timeIntervalSince1970))"
	let request = UNNotificationRequest(
		identifier: identifier,
		content: content,
		trigger: nil
	)

	center.add(request) { postError in
		if let postError = postError {
			fputs("raid-integrity-monitor-notify: error posting notification: \(postError.localizedDescription)\n", stderr)
			exitCode = 2
		}
		DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
	}
}

// Run the proper AppKit event loop. The terminate() calls above will stop it.
app.run()
exit(exitCode)
