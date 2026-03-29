import Foundation

// ---------------------------------------------------------------------------
// MARK: - RAID Scanner
//
// Runs `diskutil appleRAID list`, parses the output with a Swift state-machine
// (equivalent of the v1 AWK parser), optionally checks SMART health via
// `diskutil info`, and returns structured RAIDArrayInfo values plus Alerts.
//
// The scanner has no direct database or notification side-effects — callers
// are responsible for dispatching alerts.
// ---------------------------------------------------------------------------

public struct RAIDScanner {

	// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
	private let config: RAIDConfig
	private let logger: Logger

	// ============================================================================
	public init(
		config: RAIDConfig,
		logger: Logger
	) {
		self.config = config
		self.logger = logger
	}

	// MARK: - Public API

	// ============================================================================
	/// Run a full RAID + optional SMART check. Returns (arrays, alerts).
	public func scan() throws -> ([RAIDArrayInfo], [Alert]) {
		guard config.enabled else {
			logger.debug("RAID scanning disabled in config — skipping")
			return ([], [])
		}

		let output = try runDiskutil()
		var arrays = RAIDOutputParser.parse(output)

		if arrays.isEmpty {
			logger.warn("No Apple-RAID sets found — \(Logger.c("array may be unavailable", .boldYellow))")
			let unavailableAlert = Alert(
				title: "RAID Array Unavailable",
				subtitle: "No arrays detected",
				body: "diskutil appleRAID list returned no arrays. The RAID enclosure may be powered off or disconnected.",
				severity: .warning
			)
			return ([], [unavailableAlert])
		} else {
			logger.info("Found \(Logger.c("\(arrays.count)", .boldWhite)) Apple-RAID set(s)")
		}

		// SMART check for configured member disks
		if !config.memberDisks.isEmpty {
			arrays = arrays.map { array in
				var updated = array
				updated.members = array.members.map { member in
					var updatedMember = member
					let parentDisk = parentDisk(from: member.devNode)
					if config.memberDisks.contains(parentDisk) || config.memberDisks.contains(member.devNode) {
						updatedMember.smartStatus = checkSMART(disk: parentDisk)
						logger.info("SMART: \(Logger.c("/dev/\(parentDisk)", .dim)) (\(member.devNode)): \(Logger.c(updatedMember.smartStatus.rawValue, updatedMember.smartStatus.rawValue == "Verified" ? .green : .boldRed))")
					}
					return updatedMember
				}
				return updated
			}
		}

		let alerts = buildAlerts(for: arrays)
		return (arrays, alerts)
	}

	// MARK: - Process helpers

	// ============================================================================
	private func runDiskutil() throws -> String {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
		process.arguments = ["appleRAID", "list"]

		let stdout = Pipe()
		let stderr = Pipe()
		process.standardOutput = stdout
		process.standardError = stderr

		do {
			try process.run()
		} catch {
			throw AppError.processFailure(
				command: "diskutil appleRAID list",
				exitCode: -1,
				stderr: error.localizedDescription
			)
		}
		process.waitUntilExit()

		let output = String(
			data: stdout.fileHandleForReading.readDataToEndOfFile(),
			encoding: .utf8
		) ?? ""
		let errText = String(
			data: stderr.fileHandleForReading.readDataToEndOfFile(),
			encoding: .utf8
		) ?? ""

		if process.terminationStatus != 0 {
			throw AppError.processFailure(
				command: "diskutil appleRAID list",
				exitCode: process.terminationStatus,
				stderr: errText
			)
		}
		return output
	}

	// MARK: - SMART via diskutil info

	// ============================================================================
	private func checkSMART(disk: String) -> SMARTStatus {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
		process.arguments = ["info", "/dev/\(disk)"]

		let stdout = Pipe()
		process.standardOutput = stdout
		process.standardError = Pipe()	// discard stderr

		guard (try? process.run()) != nil else { return .unknown }
		process.waitUntilExit()

		let output = String(
			data: stdout.fileHandleForReading.readDataToEndOfFile(),
			encoding: .utf8
		) ?? ""

		// Look for "SMART Status:			  Verified" or "Failing"
		for line in output.components(separatedBy: "\n") {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("SMART Status:") {
				let value = trimmed
					.dropFirst("SMART Status:".count)
					.trimmingCharacters(in: .whitespaces)
				switch value {
				case "Verified":  return .passed
				case "Failing":	  return .failed
				case "Not Supported": return .unsupported
				default:		  return .unknown
				}
			}
		}
		return .unknown
	}

	// ============================================================================
	/// Strip partition suffix: disk8s2 → disk8, disk10s2 → disk10, disk8 → disk8
	private func parentDisk(from devNode: String) -> String {
		// Remove trailing "sN" where N is one or more digits
		if let range = devNode.range(of: #"s\d+$"#, options: .regularExpression) {
			return String(devNode[devNode.startIndex..<range.lowerBound])
		}
		return devNode
	}

	// MARK: - Alert generation

	// ============================================================================
	private func buildAlerts(for arrays: [RAIDArrayInfo]) -> [Alert] {
		var alerts: [Alert] = []
		for array in arrays {
			if array.isFailed {
				alerts.append(Alert(
					title: "RAID Array Failed",
					subtitle: array.name,
					body: "Array '\(array.name)' has failed. Immediate action required.\n\(memberSummary(array))",
					severity: .critical
				))
			} else if array.isDegraded {
				alerts.append(Alert(
					title: "RAID Array Degraded",
					subtitle: array.name,
					body: "Array '\(array.name)' is degraded.\n\(memberSummary(array))",
					severity: .warning
				))
			}

			for member in array.members where member.smartStatus == .failed {
				alerts.append(Alert(
					title: "Drive SMART Failure",
					subtitle: array.name,
					body: "Drive /dev/\(member.devNode) in array '\(array.name)' is reporting a SMART failure.",
					severity: .critical
				))
			}
		}
		return alerts
	}

	// ============================================================================
	private func memberSummary(_ array: RAIDArrayInfo) -> String {
		array.members.map { "  /dev/\($0.devNode): \($0.status)" }.joined(separator: "\n")
	}
}

// ---------------------------------------------------------------------------
// MARK: - diskutil output parser
//
// Equivalent of v1's AWK parser, ported to a Swift state machine.
// Parses the plain-text output of `diskutil appleRAID list`.
// ---------------------------------------------------------------------------

struct RAIDOutputParser {

	enum State {
		case initial
		case inArray
		case inMembers
	}

	// ============================================================================
	static func parse(_ output: String) -> [RAIDArrayInfo] {
		var arrays: [RAIDArrayInfo] = []
		var state: State = .initial

		// Working vars for the current array being parsed
		var currentUUID = ""
		var currentName = ""
		var currentStatus = ""
		var currentMembers: [RAIDMemberInfo] = []

		let lines = output.components(separatedBy: "\n")

		func flushArray() {
			guard !currentUUID.isEmpty || !currentName.isEmpty else { return }
			arrays.append(RAIDArrayInfo(
				uuid: currentUUID,
				name: currentName,
				status: currentStatus,
				members: currentMembers
			))
		}

		func resetArray() {
			currentUUID = ""
			currentName = ""
			currentStatus = ""
			currentMembers = []
		}

		for line in lines {
			let trimmed = line.trimmingCharacters(in: .whitespaces)

			// "AppleRAID sets (N found)" — informational, skip
			if trimmed.hasPrefix("AppleRAID sets (") { continue }

			// ===...=== separator — start of a new array block
			if isRule(trimmed, char: "=") {
				if state != .initial {
					flushArray()
					resetArray()
				}
				state = .inArray
				continue
			}

			// Nothing to parse until we've seen the first === block
			if state == .initial { continue }

			// ---...--- separator — start of member list
			if isRule(trimmed, char: "-") {
				state = .inMembers
				continue
			}

			// Skip the member-list column header
			if trimmed.hasPrefix("#") && trimmed.contains("DevNode") { continue }

			switch state {
			case .initial:
				break

			case .inArray:
				if trimmed.hasPrefix("Name:") {
					currentName = trimmed.dropPrefix("Name:").trimmingCharacters(in: .whitespaces)
				} else if trimmed.hasPrefix("Unique ID:") {
					currentUUID = trimmed.dropPrefix("Unique ID:").trimmingCharacters(in: .whitespaces)
				} else if trimmed.hasPrefix("Status:") {
					currentStatus = trimmed.dropPrefix("Status:").trimmingCharacters(in: .whitespaces)
				}

			case .inMembers:
				if let member = parseMemberLine(line) {
					currentMembers.append(member)
				}
			}
		}

		// Flush the last array
		if state != .initial {
			flushArray()
		}

		return arrays
	}

	// MARK: - Helpers

	// ============================================================================
	/// Returns true if the line is entirely a sequence of `char` (min 5).
	private static func isRule(
		_ line: String,
		char: Character
	) -> Bool {
		guard line.count >= 5 else { return false }
		return line.allSatisfy { $0 == char }
	}

	// ============================================================================
	/// Parse a member line.
	/// Format: "  N  diskXsY  UUID	 Status	 [Size]"
	/// Status may contain spaces, e.g. "8% (Rebuilding)".
	/// Size field looks like "3.64 TB (4000443039744 Bytes)" — we strip it.
	private static func parseMemberLine(_ rawLine: String) -> RAIDMemberInfo? {
		let line = rawLine.trimmingCharacters(in: .whitespaces)

		// Must start with a digit (member index)
		guard let first = line.first, first.isNumber else { return nil }

		var tokens = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

		// tokens[0] = member index (e.g. "0")
		// tokens[1] = devNode	   (e.g. "disk8s2")
		// tokens[2] = UUID
		// tokens[3...] = status + optional size
		guard tokens.count >= 4 else { return nil }

		let devNode = tokens[1]
		tokens.removeFirst(3)  // drop index, devNode, UUID

		// Reconstruct the remaining as a single string, then strip the trailing size field.
		// Size looks like: "N.N TB (N Bytes)" or just "N Bytes"
		var statusTokens = tokens
		statusTokens = stripSizeSuffix(statusTokens)
		let status = statusTokens.joined(separator: " ")

		return RAIDMemberInfo(
			devNode: devNode,
			status: status.isEmpty ? "Unknown" : status
		)
	}

	// ============================================================================
	/// Strips trailing size tokens from a member token array.
	/// Handles forms like: "3.64 TB (4000443039744 Bytes)" and "4000443039744 Bytes"
	private static func stripSizeSuffix(_ tokens: [String]) -> [String] {
		var result = tokens

		// Drop "Bytes)" from the end
		while result.last == "Bytes)" || result.last?.hasSuffix("Bytes)") == true {
			result.removeLast()
		}
		// Drop the raw byte count "(N"
		while let last = result.last, last.hasPrefix("("), last.dropFirst().allSatisfy({ $0.isNumber }) {
			result.removeLast()
		}
		// Drop unit: TB, GB, MB, KB, Bytes
		if ["TB", "GB", "MB", "KB", "Bytes"].contains(result.last ?? "") {
			result.removeLast()
		}
		// Drop numeric size like "3.64"
		if let last = result.last, last.first?.isNumber == true, last.contains(".") || last.allSatisfy({ $0.isNumber || $0 == "." }) {
			result.removeLast()
		}

		return result
	}
}

// MARK: - String helpers

private extension String {

	// ============================================================================
	func dropPrefix(_ prefix: String) -> String {
		guard hasPrefix(prefix) else { return self }
		return String(dropFirst(prefix.count))
	}
}
