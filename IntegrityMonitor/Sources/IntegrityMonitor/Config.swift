import Foundation

// ---------------------------------------------------------------------------
// MARK: - Config struct tree (matches spec §9)
// ---------------------------------------------------------------------------

public struct Config: Codable {

	// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
	public var watchPaths: [String]
	public var exclude: ExclusionConfig
	public var hashAlgorithm: String
	public var database: DatabaseConfig
	public var notifications: NotificationConfig
	public var performance: PerformanceConfig
	public var logging: LoggingConfig
	public var raid: RAIDConfig
	public var schedule: ScheduleConfig

	// ============================================================================
	public init(
		watchPaths: [String] = [],
		exclude: ExclusionConfig = ExclusionConfig(),
		hashAlgorithm: String = "sha256",
		database: DatabaseConfig = DatabaseConfig(),
		notifications: NotificationConfig = NotificationConfig(),
		performance: PerformanceConfig = PerformanceConfig(),
		logging: LoggingConfig = LoggingConfig(),
		raid: RAIDConfig = RAIDConfig(),
		schedule: ScheduleConfig = ScheduleConfig()
	) {
		self.watchPaths = watchPaths
		self.exclude = exclude
		self.hashAlgorithm = hashAlgorithm
		self.database = database
		self.notifications = notifications
		self.performance = performance
		self.logging = logging
		self.raid = raid
		self.schedule = schedule
	}

	// Custom decoder so missing keys fall back to defaults instead of throwing.
	// ============================================================================
	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		watchPaths			  = try container.decode([String].self, forKey: .watchPaths)
		exclude				  = try container.decodeIfPresent(ExclusionConfig.self,	   forKey: .exclude)			   ?? ExclusionConfig()
		hashAlgorithm		  = try container.decodeIfPresent(String.self,			   forKey: .hashAlgorithm)		   ?? "sha256"
		database			  = try container.decodeIfPresent(DatabaseConfig.self,	   forKey: .database)			   ?? DatabaseConfig()
		notifications		  = try container.decodeIfPresent(NotificationConfig.self, forKey: .notifications)		   ?? NotificationConfig()
		performance			  = try container.decodeIfPresent(PerformanceConfig.self,  forKey: .performance)		   ?? PerformanceConfig()
		logging				  = try container.decodeIfPresent(LoggingConfig.self,	   forKey: .logging)			   ?? LoggingConfig()
		raid				  = try container.decodeIfPresent(RAIDConfig.self,		   forKey: .raid)				   ?? RAIDConfig()
		schedule			  = try container.decodeIfPresent(ScheduleConfig.self,	   forKey: .schedule)			   ?? ScheduleConfig()
	}
}

public struct ExclusionConfig: Codable {

	// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
	public var pathPatterns: [String]
	public var directoryPatterns: [String]
	public var minSizeBytes: Int?
	public var maxSizeBytes: Int?

	// ============================================================================
	public init(
		pathPatterns: [String] = [],
		directoryPatterns: [String] = [],
		minSizeBytes: Int? = nil,
		maxSizeBytes: Int? = nil
	) {
		self.pathPatterns = pathPatterns
		self.directoryPatterns = directoryPatterns
		self.minSizeBytes = minSizeBytes
		self.maxSizeBytes = maxSizeBytes
	}

	// ============================================================================
	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		pathPatterns	  = try container.decodeIfPresent([String].self, forKey: .pathPatterns)		 ?? []
		directoryPatterns = try container.decodeIfPresent([String].self, forKey: .directoryPatterns) ?? []
		minSizeBytes	  = try container.decodeIfPresent(Int.self,		 forKey: .minSizeBytes)
		maxSizeBytes	  = try container.decodeIfPresent(Int.self,		 forKey: .maxSizeBytes)
	}
}

public struct DatabaseConfig: Codable {
	public var primary: String
	public var replica: String?

	// ============================================================================
	public init(
		primary: String = "~/.local/share/raid-integrity-monitor/manifest.db",
		replica: String? = nil
	) {
		self.primary = primary
		self.replica = replica
	}
}

public struct NotificationConfig: Codable {

	// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
	public var onCorruption: Bool
	public var onRAIDDegraded: Bool
	public var onRAIDUnavailable: Bool
	public var onMissingFile: Bool
	public var onVolumeUnavailable: Bool
	public var onScanComplete: Bool
	public var onScanCompleteWithIssues: Bool

	// ============================================================================
	public init(
		onCorruption: Bool = true,
		onRAIDDegraded: Bool = true,
		onRAIDUnavailable: Bool = true,
		onMissingFile: Bool = false,
		onVolumeUnavailable: Bool = true,
		onScanComplete: Bool = false,
		onScanCompleteWithIssues: Bool = true
	) {
		self.onCorruption = onCorruption
		self.onRAIDDegraded = onRAIDDegraded
		self.onRAIDUnavailable = onRAIDUnavailable
		self.onMissingFile = onMissingFile
		self.onVolumeUnavailable = onVolumeUnavailable
		self.onScanComplete = onScanComplete
		self.onScanCompleteWithIssues = onScanCompleteWithIssues
	}

	// ============================================================================
	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		onCorruption			 = try container.decodeIfPresent(Bool.self, forKey: .onCorruption)			   ?? true
		onRAIDDegraded			 = try container.decodeIfPresent(Bool.self, forKey: .onRAIDDegraded)		   ?? true
		onRAIDUnavailable		 = try container.decodeIfPresent(Bool.self, forKey: .onRAIDUnavailable)	   ?? true
		onMissingFile			 = try container.decodeIfPresent(Bool.self, forKey: .onMissingFile)			   ?? false
		onVolumeUnavailable		 = try container.decodeIfPresent(Bool.self, forKey: .onVolumeUnavailable)	   ?? true
		onScanComplete			 = try container.decodeIfPresent(Bool.self, forKey: .onScanComplete)		   ?? false
		onScanCompleteWithIssues = try container.decodeIfPresent(Bool.self, forKey: .onScanCompleteWithIssues) ?? true
	}
}

public struct PerformanceConfig: Codable {
	public var maxHashThreads: Int
	public var dbBatchSize: Int
	public var maxVerificationsPerRun: Int
	public var volumeThreadOverrides: [String: Int]?

	// ============================================================================
	public init(
		maxHashThreads: Int = 2,
		dbBatchSize: Int = 500,
		maxVerificationsPerRun: Int = 1000,
		volumeThreadOverrides: [String: Int]? = nil
	) {
		self.maxHashThreads = maxHashThreads
		self.dbBatchSize = dbBatchSize
		self.maxVerificationsPerRun = maxVerificationsPerRun
		self.volumeThreadOverrides = volumeThreadOverrides
	}

	// ============================================================================
	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		maxHashThreads		   = try container.decodeIfPresent(Int.self, forKey: .maxHashThreads)		 ?? 2
		dbBatchSize			   = try container.decodeIfPresent(Int.self, forKey: .dbBatchSize)			 ?? 500
		maxVerificationsPerRun = try container.decodeIfPresent(Int.self, forKey: .maxVerificationsPerRun) ?? 1000
		volumeThreadOverrides  = try container.decodeIfPresent([String: Int].self, forKey: .volumeThreadOverrides)
	}
}

public struct LoggingConfig: Codable {
	public var logPath: String
	public var level: String
	public var localTimestamps: Bool

	// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
	public var maxLogSizeBytes: Int

	// ============================================================================
	public init(
		logPath: String = "~/.local/share/raid-integrity-monitor/raid-integrity-monitor.log",
		level: String = "info",
		localTimestamps: Bool = false,
		maxLogSizeBytes: Int = 10 * 1024 * 1024
	) {
		self.logPath = logPath
		self.level = level
		self.localTimestamps = localTimestamps
		self.maxLogSizeBytes = maxLogSizeBytes
	}

	// ============================================================================
	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		logPath			 = try container.decodeIfPresent(String.self, forKey: .logPath)		      ?? "~/.local/share/raid-integrity-monitor/raid-integrity-monitor.log"
		level			 = try container.decodeIfPresent(String.self, forKey: .level)		      ?? "info"
		localTimestamps  = try container.decodeIfPresent(Bool.self,   forKey: .localTimestamps)    ?? false
		maxLogSizeBytes  = try container.decodeIfPresent(Int.self,	  forKey: .maxLogSizeBytes)    ?? (10 * 1024 * 1024)
	}
}

public struct ScheduleConfig: Codable {
	public var raidCheckIntervalMinutes: Int
	public var fileScanIntervalHours: Int
	public var verificationIntervalDays: Int

	// ============================================================================
	public init(
		raidCheckIntervalMinutes: Int = 5,
		fileScanIntervalHours: Int = 24,
		verificationIntervalDays: Int = 30
	) {
		self.raidCheckIntervalMinutes = raidCheckIntervalMinutes
		self.fileScanIntervalHours = fileScanIntervalHours
		self.verificationIntervalDays = verificationIntervalDays
	}

	// ============================================================================
	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		raidCheckIntervalMinutes  = try container.decodeIfPresent(Int.self, forKey: .raidCheckIntervalMinutes)  ?? 5
		fileScanIntervalHours	  = try container.decodeIfPresent(Int.self, forKey: .fileScanIntervalHours)	   ?? 24
		verificationIntervalDays  = try container.decodeIfPresent(Int.self, forKey: .verificationIntervalDays)  ?? 30
	}
}

public struct RAIDConfig: Codable {
	public var enabled: Bool
	public var memberDisks: [String]

	// ============================================================================
	public init(
		enabled: Bool = true,
		memberDisks: [String] = []
	) {
		self.enabled = enabled
		self.memberDisks = memberDisks
	}

	// ============================================================================
	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		enabled		= try container.decodeIfPresent(Bool.self,	   forKey: .enabled)	 ?? true
		memberDisks = try container.decodeIfPresent([String].self, forKey: .memberDisks) ?? []
	}
}

// ---------------------------------------------------------------------------
// MARK: - Path resolution (computed properties, not stored)
// ---------------------------------------------------------------------------

public extension Config {
	var resolvedWatchPaths: [URL] {
		watchPaths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
	}
}

public extension DatabaseConfig {
	var resolvedPrimary: URL {
		URL(fileURLWithPath: (primary as NSString).expandingTildeInPath)
	}
	var resolvedReplica: URL? {
		replica.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
	}
}

public extension LoggingConfig {
	var resolvedLogPath: URL {
		URL(fileURLWithPath: (logPath as NSString).expandingTildeInPath)
	}
}

// ---------------------------------------------------------------------------
// MARK: - Config loader
// ---------------------------------------------------------------------------

public struct ConfigLoader {

	// ============================================================================
	public static func defaultConfigURL() -> URL {
		let base = (("~/.config/raid-integrity-monitor" as NSString).expandingTildeInPath)
		return URL(fileURLWithPath: base).appendingPathComponent("config.json")
	}

	/// Load and validate config from `url`. Creates parent directories for database
	/// and log paths. Throws `AppError` on validation failure.
	// ============================================================================
	public static func load(from url: URL) throws -> Config {
		guard FileManager.default.fileExists(atPath: url.path) else {
			throw AppError.configNotFound(url)
		}

		let data: Data
		do {
			data = try Data(contentsOf: url)
		} catch {
			throw AppError.configValidation("Cannot read config file: \(error.localizedDescription)")
		}

		let decoder = JSONDecoder()
		let config: Config
		do {
			config = try decoder.decode(Config.self, from: data)
		} catch {
			throw AppError.configValidation("JSON parse error: \(error.localizedDescription)")
		}

		try validate(config)
		try createDirectories(for: config)
		return config
	}

	// MARK: Private helpers

	// ============================================================================
	private static func validate(_ config: Config) throws {
		if config.watchPaths.isEmpty {
			throw AppError.configValidation("watchPaths must not be empty")
		}
		var accessibleCount = 0
		for rawPath in config.watchPaths {
			let expanded = (rawPath as NSString).expandingTildeInPath
			var isDir: ObjCBool = false
			let exists = FileManager.default.fileExists(
				atPath: expanded,
				isDirectory: &isDir
			)
			if !exists || !isDir.boolValue {
				// Warn but do not abort — the volume may be temporarily
				// unmounted (e.g. external RAID enclosure powered off).
				// Phase 1 will skip inaccessible paths at scan time.
				fputs("Warning: watchPath not currently accessible: \(expanded)\n", stderr)
			} else {
				accessibleCount += 1
			}
		}
		if accessibleCount == 0 {
			throw AppError.configValidation(
				"No watchPaths are currently accessible. At least one must be reachable."
			)
		}
		if config.performance.maxHashThreads < 1 {
			throw AppError.configValidation("performance.maxHashThreads must be >= 1")
		}
		if let overrides = config.performance.volumeThreadOverrides {
			for (mountPoint, threads) in overrides {
				if threads < 1 {
					throw AppError.configValidation("volumeThreadOverrides[\(mountPoint)] must be >= 1")
				}
			}
		}
		if config.schedule.verificationIntervalDays < 1 {
			throw AppError.configValidation("schedule.verificationIntervalDays must be >= 1")
		}
		if config.performance.dbBatchSize < 1 {
			throw AppError.configValidation("performance.dbBatchSize must be >= 1")
		}
		if config.performance.maxVerificationsPerRun < 0 {
			throw AppError.configValidation("performance.maxVerificationsPerRun must be >= 0")
		}
		if config.logging.maxLogSizeBytes < 1 {
			throw AppError.configValidation("logging.maxLogSizeBytes must be >= 1")
		}
		if config.schedule.raidCheckIntervalMinutes < 1 {
			throw AppError.configValidation("schedule.raidCheckIntervalMinutes must be >= 1")
		}
		if config.schedule.fileScanIntervalHours < 1 {
			throw AppError.configValidation("schedule.fileScanIntervalHours must be >= 1")
		}
	}

	// ============================================================================
	private static func createDirectories(for config: Config) throws {
		let paths: [URL] = [
			config.database.resolvedPrimary.deletingLastPathComponent(),
			config.logging.resolvedLogPath.deletingLastPathComponent()
		]
		let replicaDir = config.database.resolvedReplica?.deletingLastPathComponent()
		let allPaths = replicaDir.map { paths + [$0] } ?? paths

		for dir in allPaths {
			do {
				try FileManager.default.createDirectory(
					at: dir,
					withIntermediateDirectories: true
				)
			} catch {
				throw AppError.configValidation("Cannot create directory \(dir.path): \(error.localizedDescription)")
			}
		}
	}
}
