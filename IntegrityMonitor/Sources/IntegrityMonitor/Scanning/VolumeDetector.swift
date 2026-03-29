import Foundation

// ---------------------------------------------------------------------------
// MARK: - VolumeInfo
//
// Describes a mounted volume and the hashing concurrency to use for files
// on that volume.
// ---------------------------------------------------------------------------

public struct VolumeInfo: Sendable {

	// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

	public let mountPoint: String
	public let deviceID: dev_t
	public let isSSD: Bool?
	public let maxHashThreads: Int
}

// ---------------------------------------------------------------------------
// MARK: - VolumeDetector
//
// Detects mounted volumes for the configured watch paths and resolves
// per-volume hashing concurrency.  Uses POSIX stat()/getmntinfo() for
// volume resolution and `diskutil info` for SSD detection.
// ---------------------------------------------------------------------------

public struct VolumeDetector {

	// Default thread counts by disk type
	private static let ssdDefaultThreads = 4
	private static let hddDefaultThreads = 1

	// ============================================================================
	/// Detect volumes for all watch paths.  Returns one entry per unique device,
	/// keyed by `dev_t`.
	public static func detectVolumes(
		for watchPaths: [URL],
		globalMaxThreads: Int,
		overrides: [String: Int],
		logger: Logger
	) -> [dev_t: VolumeInfo] {
		var result: [dev_t: VolumeInfo] = [:]

		for watchURL in watchPaths {
			guard let (devID, mountPoint) = resolveVolume(for: watchURL.path) else {
				logger.warn("Cannot determine volume for \(Logger.c(watchURL.path, .cyan))")
				continue
			}

			// Skip if we already resolved this device
			guard result[devID] == nil else { continue }

			let isSSD = detectSolidState(mountPoint: mountPoint)
			let threads = resolveThreadCount(
				mountPoint: mountPoint,
				isSSD: isSSD,
				globalMaxThreads: globalMaxThreads,
				overrides: overrides
			)

			let diskType: String
			if let ssd = isSSD {
				diskType = ssd ? "SSD" : "HDD"
			} else {
				diskType = "unknown"
			}
			logger.info("Volume \(Logger.c(mountPoint, .cyan)): \(diskType), \(Logger.c("\(threads)", .boldWhite)) hash thread(s)")

			result[devID] = VolumeInfo(
				mountPoint: mountPoint,
				deviceID: devID,
				isSSD: isSSD,
				maxHashThreads: threads
			)
		}

		return result
	}

	// ============================================================================
	/// Return the device ID for a file path via POSIX stat().
	public static func deviceID(for path: String) -> dev_t {
		var statBuf = stat()
		guard stat(path, &statBuf) == 0 else { return 0 }
		return statBuf.st_dev
	}

	// MARK: - Private helpers

	// ============================================================================
	/// Resolve a path to its volume's device ID and mount point.
	private static func resolveVolume(for path: String) -> (dev_t, String)? {
		var statBuf = stat()
		guard stat(path, &statBuf) == 0 else { return nil }
		let targetDev = statBuf.st_dev

		// Use getmntinfo to find the mount point for this device
		var mntBuf: UnsafeMutablePointer<statfs>?
		let count = getmntinfo(&mntBuf, MNT_NOWAIT)
		guard count > 0, let entries = mntBuf else { return nil }

		for index in 0..<Int(count) {
			let entry = entries[index]
			// stat the mount point to get its dev_t
			var mountStat = Darwin.stat()
			let mountPath = withUnsafePointer(to: entry.f_mntonname) {
				$0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
					String(cString: $0)
				}
			}
			guard stat(mountPath, &mountStat) == 0 else { continue }
			if mountStat.st_dev == targetDev {
				return (targetDev, mountPath)
			}
		}

		return nil
	}

	// ============================================================================
	/// Detect whether a volume is SSD via `diskutil info`.
	/// Returns nil if detection fails.
	private static func detectSolidState(mountPoint: String) -> Bool? {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
		process.arguments = ["info", mountPoint]

		let stdout = Pipe()
		process.standardOutput = stdout
		process.standardError = Pipe()

		guard (try? process.run()) != nil else { return nil }
		process.waitUntilExit()

		guard process.terminationStatus == 0 else { return nil }

		let output = String(
			data: stdout.fileHandleForReading.readDataToEndOfFile(),
			encoding: .utf8
		) ?? ""

		for line in output.components(separatedBy: "\n") {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("Solid State:") {
				let value = trimmed
					.dropFirst("Solid State:".count)
					.trimmingCharacters(in: .whitespaces)
				switch value {
				case "Yes": return true
				case "No":  return false
				default:    return nil
				}
			}
		}
		return nil
	}

	// ============================================================================
	/// Resolve the thread count for a volume.
	/// Priority: manual override > auto-detected default > global fallback.
	private static func resolveThreadCount(
		mountPoint: String,
		isSSD: Bool?,
		globalMaxThreads: Int,
		overrides: [String: Int]
	) -> Int {
		if let override = overrides[mountPoint] {
			return override
		}
		if let ssd = isSSD {
			return ssd ? ssdDefaultThreads : hddDefaultThreads
		}
		return globalMaxThreads
	}
}
