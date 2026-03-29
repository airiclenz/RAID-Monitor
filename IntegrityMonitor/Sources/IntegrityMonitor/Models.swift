import Foundation

// ---------------------------------------------------------------------------
// MARK: - File manifest
// ---------------------------------------------------------------------------

public struct FileRecord: Equatable, Sendable {
	public var id: Int64?
	public var path: String
	public var size: Int64
	public var mtime: Date
	public var hash: String
	public var hashAlgorithm: String
	public var firstSeen: Date
	public var lastVerified: Date
	public var lastModified: Date?
	public var status: FileStatus

	// ============================================================================
	public init(
		id: Int64? = nil,
		path: String,
		size: Int64,
		mtime: Date,
		hash: String,
		hashAlgorithm: String,
		firstSeen: Date,
		lastVerified: Date,
		lastModified: Date? = nil,
		status: FileStatus = .ok
	) {
		self.id = id
		self.path = path
		self.size = size
		self.mtime = mtime
		self.hash = hash
		self.hashAlgorithm = hashAlgorithm
		self.firstSeen = firstSeen
		self.lastVerified = lastVerified
		self.lastModified = lastModified
		self.status = status
	}
}

public enum FileStatus: String, Codable, Sendable {
	case ok
	case new
	case modified
	case corrupted
}

// ---------------------------------------------------------------------------
// MARK: - Scan tracking
// ---------------------------------------------------------------------------

public struct ScanResult {
	public var id: Int64?
	public var startedAt: Date
	public var completedAt: Date?
	public var filesWalked: Int
	public var filesSkipped: Int
	public var filesNew: Int
	public var filesModified: Int
	public var filesVerified: Int
	public var filesCorrupted: Int
	public var filesMissing: Int
	public var filesUpgraded: Int
	public var status: ScanStatus

	// ============================================================================
	public init(
		id: Int64? = nil,
		startedAt: Date = Date(),
		completedAt: Date? = nil,
		filesWalked: Int = 0,
		filesSkipped: Int = 0,
		filesNew: Int = 0,
		filesModified: Int = 0,
		filesVerified: Int = 0,
		filesCorrupted: Int = 0,
		filesMissing: Int = 0,
		filesUpgraded: Int = 0,
		status: ScanStatus = .running
	) {
		self.id = id
		self.startedAt = startedAt
		self.completedAt = completedAt
		self.filesWalked = filesWalked
		self.filesSkipped = filesSkipped
		self.filesNew = filesNew
		self.filesModified = filesModified
		self.filesVerified = filesVerified
		self.filesCorrupted = filesCorrupted
		self.filesMissing = filesMissing
		self.filesUpgraded = filesUpgraded
		self.status = status
	}
}

public enum ScanStatus: String, Codable {
	case running
	case completed
	case interrupted
	case failed
}

// ---------------------------------------------------------------------------
// MARK: - Events (append-only audit log)
// ---------------------------------------------------------------------------

public struct ScanEvent {
	public var id: Int64?
	public var timestamp: Date
	public var eventType: String
	public var path: String?
	public var detail: String?	// JSON string

	// ============================================================================
	public init(
		id: Int64? = nil,
		timestamp: Date = Date(),
		eventType: String,
		path: String? = nil,
		detail: String? = nil
	) {
		self.id = id
		self.timestamp = timestamp
		self.eventType = eventType
		self.path = path
		self.detail = detail
	}
}

public extension ScanEvent {
	// Well-known event type constants
	static let scanStart = "scan_start"
	static let scanComplete = "scan_complete"
	static let fileNew = "file_new"
	static let fileModified = "file_modified"
	static let fileCorrupted = "file_corrupted"
	static let fileMissing = "file_missing"
	static let raidDegraded = "raid_degraded"
	static let raidFailed = "raid_failed"
	static let raidDisappeared = "raid_disappeared"
	static let raidOnline = "raid_online"
	static let smartFailed = "smart_failed"
	static let hashUpgradeStart = "hash_upgrade_start"
	static let hashUpgradeComplete = "hash_upgrade_complete"
}

// ---------------------------------------------------------------------------
// MARK: - RAID
// ---------------------------------------------------------------------------

public struct RAIDArrayInfo: Equatable {
	public var uuid: String
	public var name: String
	public var status: String
	public var members: [RAIDMemberInfo]

	// ============================================================================
	public init(
		uuid: String,
		name: String,
		status: String,
		members: [RAIDMemberInfo]
	) {
		self.uuid = uuid
		self.name = name
		self.status = status
		self.members = members
	}

	// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
	// Computed properties

	public var isDegraded: Bool { status == "Degraded" }
	public var isFailed: Bool { status == "Failed" }
	public var isOnline: Bool { status == "Online" }
}

public struct RAIDMemberInfo: Equatable {
	public var devNode: String
	public var status: String
	public var smartStatus: SMARTStatus

	// ============================================================================
	public init(
		devNode: String,
		status: String,
		smartStatus: SMARTStatus = .unknown
	) {
		self.devNode = devNode
		self.status = status
		self.smartStatus = smartStatus
	}
}

public enum SMARTStatus: String {
	case passed = "Verified"
	case failed = "Failing"
	case unsupported
	case unknown
}

// ---------------------------------------------------------------------------
// MARK: - Alerts / Notifications
// ---------------------------------------------------------------------------

public struct Alert {
	public var title: String
	public var subtitle: String
	public var body: String
	public var severity: AlertSeverity
	public var timestamp: Date

	// ============================================================================
	public init(
		title: String,
		subtitle: String = "",
		body: String,
		severity: AlertSeverity,
		timestamp: Date = Date()
	) {
		self.title = title
		self.subtitle = subtitle
		self.body = body
		self.severity = severity
		self.timestamp = timestamp
	}
}

public enum AlertSeverity: String {
	case info
	case warning
	case critical
}

// ---------------------------------------------------------------------------
// MARK: - Errors
// ---------------------------------------------------------------------------

public enum AppError: Error, CustomStringConvertible {
	case configNotFound(URL)
	case configValidation(String)
	case database(String)
	case hashMismatch(path: String, stored: String, computed: String)
	case unsupportedHashAlgorithm(String)
	case processFailure(command: String, exitCode: Int32, stderr: String)
	case fileAccess(path: String, underlying: Error)

	// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
	// Computed properties

	public var description: String {
		switch self {
		case .configNotFound(let configUrl):
			return "Config file not found: \(configUrl.path)"
		case .configValidation(let message):
			return "Config validation error: \(message)"
		case .database(let message):
			return "Database error: \(message)"
		case .hashMismatch(let path, let stored, let computed):
			return "Hash mismatch for \(path): stored=\(stored.prefix(8))... computed=\(computed.prefix(8))..."
		case .unsupportedHashAlgorithm(let algorithm):
			return "Unsupported hash algorithm: \(algorithm)"
		case .processFailure(let command, let exitCode, let standardError):
			return "Process '\(command)' failed with exit code \(exitCode): \(standardError)"
		case .fileAccess(let path, let underlyingError):
			return "Cannot access \(path): \(underlyingError.localizedDescription)"
		}
	}
}
