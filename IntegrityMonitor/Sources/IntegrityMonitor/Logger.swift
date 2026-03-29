import Foundation

// ---------------------------------------------------------------------------
// MARK: - Terminal colors
//
// ANSI escape codes for terminal-only coloring. Use Logger.c(_:_:) to wrap
// text segments — colors are automatically stripped from log-file output and
// from non-TTY stdout.
// ---------------------------------------------------------------------------

public enum TermColor: String {
	case reset		= "\u{1B}[0m"
	case bold		= "\u{1B}[1m"
	case dim		= "\u{1B}[2m"

	case red		= "\u{1B}[31m"
	case green		= "\u{1B}[32m"
	case yellow		= "\u{1B}[33m"
	case blue		= "\u{1B}[34m"
	case magenta	= "\u{1B}[35m"
	case cyan		= "\u{1B}[36m"
	case white		= "\u{1B}[37m"

	case boldRed	= "\u{1B}[1;31m"
	case boldGreen	= "\u{1B}[1;32m"
	case boldYellow	= "\u{1B}[1;33m"
	case boldCyan	= "\u{1B}[1;34m"
	case boldWhite	= "\u{1B}[1;37m"
}

// ---------------------------------------------------------------------------
// MARK: - Logger
//
// Synchronous, NSLock-based logger. Safe to call from any context (sync or
// async) without await. Writes ISO-8601 UTC timestamps and rotates the log
// file when it exceeds maxBytes (one archive: .log.1).
//
// Terminal color support: embed ANSI codes in log messages via Logger.c().
// Colors are rendered to stdout when attached to a TTY and stripped from
// all log-file output.
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

		// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

		/// ANSI color used for the level tag in terminal output.
		var termColor: TermColor {
			switch self {
			case .debug: return .dim
			case .info:	 return .cyan
			case .warn:	 return .boldYellow
			case .error: return .boldRed
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

	/// True when stdout is a TTY — enables colored terminal output.
	private let colorEnabled: Bool

	// MARK: - Color helper

	// ============================================================================
	/// Wrap `text` in ANSI color codes. Multiple colors can be combined by
	/// calling this multiple times within the same string interpolation:
	///
	///     logger.info("\(Logger.c("Phase 1:", .boldCyan)) walked \(Logger.c("1234", .boldWhite)) files")
	///
	/// The Logger strips all ANSI codes before writing to the log file,
	/// so colored messages are safe to use everywhere.
	public static func c(
		_ text: String,
		_ color: TermColor
	) -> String {
		return "\(color.rawValue)\(text)\(TermColor.reset.rawValue)"
	}

	/// Regex that matches any ANSI CSI escape sequence.
	private static let ansiPattern = try! NSRegularExpression(
		pattern: "\u{1B}\\[[0-9;]*m"
	)

	// ============================================================================
	/// Strip all ANSI escape codes from a string.
	private static func stripANSI(_ string: String) -> String {
		return ansiPattern.stringByReplacingMatches(
			in: string,
			range: NSRange(string.startIndex..., in: string),
			withTemplate: ""
		)
	}

	// ============================================================================
	public init(
		path: URL,
		level: Level = .info,
		maxBytes: Int = 10 * 1024 * 1024,
		localTimestamps: Bool = false
	) {
		self.path = path
		self.minimumLevel = level
		self.maxBytes = maxBytes
		self.formatter = ISO8601DateFormatter()
		self.formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		self.formatter.timeZone = localTimestamps ? TimeZone.current : TimeZone(identifier: "UTC")!
		self.colorEnabled = isatty(STDOUT_FILENO) != 0
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

		// File line: always plain text (no ANSI codes)
		let plainMessage = Self.stripANSI(message)
		let fileLine = "[\(timestamp)] [\(level)] \(plainMessage)\n"

		// Terminal line: colored level tag + original colored message
		let terminalLine: String
		if colorEnabled {
			let coloredLevel = "\(level.termColor.rawValue)\(level)\(TermColor.reset.rawValue)"
			terminalLine = "\(TermColor.dim.rawValue)[\(timestamp)]\(TermColor.reset.rawValue) [\(coloredLevel)] \(message)\(TermColor.reset.rawValue)\n"
		} else {
			terminalLine = fileLine
		}

		lock.lock()
		defer { lock.unlock() }

		rotateIfNeeded()

		// Append to log file (always plain text)
		if let data = fileLine.data(using: .utf8) {
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

		// Mirror to stdout for launchd log capture / interactive terminal.
		// When on a TTY, clear any in-place progress line (written to stderr
		// via \r) before emitting the log line so the two don't collide.
		if colorEnabled {
			print("\r\u{1B}[K", terminator: "")
		}
		print(terminalLine, terminator: "")
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
