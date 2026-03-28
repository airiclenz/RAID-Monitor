import Foundation

// ---------------------------------------------------------------------------
// MARK: - AlertChannel protocol
// ---------------------------------------------------------------------------

public protocol AlertChannel {
	func send(_ alert: Alert)
}

// ---------------------------------------------------------------------------
// MARK: - macOS notification channel (via raid-integrity-monitor-notify app bundle)
// ---------------------------------------------------------------------------

public struct MacOSAlertChannel: AlertChannel {

	/// Path to the installed notify binary inside the app bundle.
	/// e.g. ~/bin/raid-integrity-monitor-notify.app/Contents/MacOS/raid-integrity-monitor-notify
	private let notifyBinaryPath: String
	private let logger: Logger

	// ============================================================================
	public init(
		notifyBinaryPath: String,
		logger: Logger
	) {
		self.notifyBinaryPath = notifyBinaryPath
		self.logger = logger
	}

	// ============================================================================
	public func send(_ alert: Alert) {
		guard FileManager.default.isExecutableFile(atPath: notifyBinaryPath) else {
			logger.warn("Notification helper not found or not executable: \(notifyBinaryPath)")
			return
		}

		let process = Process()
		process.executableURL = URL(fileURLWithPath: notifyBinaryPath)
		process.arguments = [
			"--title", alert.title,
			"--subtitle", alert.subtitle,
			"--body", alert.body,
			"--level", alert.severity.rawValue
		]

		do {
			try process.run()
			// Fire-and-forget: the notify helper has its own 10-second timeout
			// and exits via NSApplication.terminate(nil). Waiting here would block
			// the FileScanner actor thread, stalling all scan work.
		} catch {
			logger.warn("Failed to launch notification helper: \(error)")
		}
	}
}

// ---------------------------------------------------------------------------
// MARK: - AlertManager
//
// Applies the NotificationConfig rules before dispatching to channels.
// Corruption alerts always fire (never silenced by config).
// ---------------------------------------------------------------------------

public struct AlertManager {

	private let channels: [any AlertChannel]
	private let config: NotificationConfig
	private let logger: Logger

	// ============================================================================
	public init(
		channels: [any AlertChannel],
		config: NotificationConfig,
		logger: Logger
	) {
		self.channels = channels
		self.config = config
		self.logger = logger
	}

	// ============================================================================
	public func send(_ alert: Alert) {
		logger.info("Alert [\(alert.severity.rawValue.uppercased())] \(alert.title): \(alert.body.prefix(100))")
		for channel in channels {
			channel.send(alert)
		}
	}

	// MARK: - Convenience factory methods for common alert types

	// ============================================================================
	public func sendIfEnabled(corruption alert: Alert) {
		// Corruption is always sent — non-silenceable
		send(alert)
	}

	// ============================================================================
	public func sendIfEnabled(raidAlert alert: Alert) {
		guard config.onRAIDDegraded else { return }
		send(alert)
	}

	// ============================================================================
	public func sendIfEnabled(missingFile alert: Alert) {
		guard config.onMissingFile else { return }
		send(alert)
	}

	// ============================================================================
	public func sendIfEnabled(
		scanComplete alert: Alert,
		hasIssues: Bool
	) {
		if hasIssues {
			guard config.onScanCompleteWithIssues else { return }
		} else {
			guard config.onScanComplete else { return }
		}
		send(alert)
	}
}
