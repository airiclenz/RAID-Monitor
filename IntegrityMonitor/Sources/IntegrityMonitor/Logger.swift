import Foundation

// ---------------------------------------------------------------------------
// MARK: - Logger
//
// Synchronous, NSLock-based logger. Safe to call from any context (sync or
// async) without await. Writes ISO-8601 UTC timestamps and rotates the log
// file when it exceeds maxBytes (one archive: .log.1).
// ---------------------------------------------------------------------------

public final class Logger: @unchecked Sendable {

	public enum Level: Int, Comparable, CustomStringConvertible {
		case debug = 0
		case info  = 1
		case warn  = 2
		case error = 3

		// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

		public var description: String {
			switch self {
			case .debug: return "DEBUG"
			case .info:	 return "INFO "
			case .warn:	 return "WARN "
			case .error: return "ERROR"
			}
		}

		// ============================================================================
		public static func < (
			lhs: Level,
			rhs: Level
		) -> Bool {
			lhs.rawValue < rhs.rawValue
		}

		// ============================================================================
		public static func from(string: String) -> Level {
			switch string.lowercased() {
			case "debug": return .debug
			case "warn", "warning": return .warn
			case "error": return .error
			default: return .info
			}
		}
	}

	// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

	private let path: URL
	private let minimumLevel: Level
	private let maxBytes: Int
	private let lock = NSLock()
	private let formatter: ISO8601DateFormatter

	// ============================================================================
	public init(
		path: URL,
		level: Level = .info,
		maxBytes: Int = 10 * 1024 * 1024
	) {
		self.path = path
		self.minimumLevel = level
		self.maxBytes = maxBytes
		self.formatter = ISO8601DateFormatter()
		self.formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		self.formatter.timeZone = TimeZone(identifier: "UTC")
	}

	// MARK: - Public interface

	// ============================================================================
	public func debug(_ message: String) { write(.debug, message) }

	// ============================================================================
	public func info(_ message: String) { write(.info, message) }

	// ============================================================================
	public func warn(_ message: String) { write(.warn, message) }

	// ============================================================================
	public func error(_ message: String) { write(.error, message) }

	// MARK: - Core write

	// ============================================================================
	private func write(
		_ level: Level,
		_ message: String
	) {
		guard level >= minimumLevel else { return }

		let timestamp = formatter.string(from: Date())
		let line = "[\(timestamp)] [\(level)] \(message)\n"

		lock.lock()
		defer { lock.unlock() }

		rotateIfNeeded()

		// Append to log file
		if let data = line.data(using: .utf8) {
			if FileManager.default.fileExists(atPath: path.path) {
				if let handle = try? FileHandle(forWritingTo: path) {
					handle.seekToEndOfFile()
					handle.write(data)
					try? handle.close()
				}
			} else {
				try? data.write(to: path, options: .atomic)
			}
		}

		// Mirror to stdout for launchd log capture
		print(line, terminator: "")
	}

	// MARK: - Rotation

	// ============================================================================
	private func rotateIfNeeded() {
		guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
			  let size = attrs[.size] as? Int,
			  size >= maxBytes else { return }

		let archive = URL(fileURLWithPath: path.path + ".1")
		try? FileManager.default.removeItem(at: archive)
		try? FileManager.default.moveItem(at: path, to: archive)
	}
}
