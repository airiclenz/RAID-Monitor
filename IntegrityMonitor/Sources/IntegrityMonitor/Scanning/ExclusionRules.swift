import Foundation
import Darwin

// ---------------------------------------------------------------------------
// MARK: - ExclusionRules
//
// Determines whether a file or directory should be included in the scan.
// Uses fnmatch(3) glob syntax with FNM_CASEFOLD (case-insensitive, appropriate
// for HFS+). Patterns are matched against both the full path and the filename.
// ---------------------------------------------------------------------------

public struct ExclusionRules {

	private let pathPatterns: [String]
	private let directoryPatterns: [String]
	private let minSizeBytes: Int?
	private let maxSizeBytes: Int?

	// ============================================================================
	public init(config: ExclusionConfig) {
		self.pathPatterns = config.pathPatterns
		self.directoryPatterns = config.directoryPatterns
		self.minSizeBytes = config.minSizeBytes
		self.maxSizeBytes = config.maxSizeBytes
	}

	// MARK: - Public interface

	// ============================================================================
	/// Returns `false` if the scanner should NOT descend into `directoryURL`.
	/// Called before `FileManager.enumerator` would recurse into the directory.
	public func shouldDescend(into directoryURL: URL) -> Bool {
		let name = directoryURL.lastPathComponent
		for pattern in directoryPatterns {
			if fnmatchCaseInsensitive(pattern: pattern, string: name) { return false }
		}
		return true
	}

	// ============================================================================
	/// Returns `false` if the file should be skipped (excluded from scanning).
	public func shouldInclude(
		fileAt url: URL,
		size: Int
	) -> Bool {
		// Size bounds
		if let min = minSizeBytes, size < min { return false }
		if let max = maxSizeBytes, size > max { return false }

		// Path pattern matching — checked against full path and filename
		let fullPath = url.path
		let fileName = url.lastPathComponent
		for pattern in pathPatterns {
			if fnmatchCaseInsensitive(pattern: pattern, string: fullPath) { return false }
			if fnmatchCaseInsensitive(pattern: pattern, string: fileName) { return false }
		}
		return true
	}

	// MARK: - fnmatch wrapper

	// ============================================================================
	/// Returns `true` if `string` matches `pattern` using fnmatch with FNM_CASEFOLD.
	private func fnmatchCaseInsensitive(
		pattern: String,
		string: String
	) -> Bool {
		// FNM_CASEFOLD = 0x10 (Darwin extension for case-insensitive matching)
		let FNM_CASEFOLD: Int32 = 0x10
		return pattern.withCString { patCStr in
			string.withCString { strCStr in
				Darwin.fnmatch(patCStr, strCStr, FNM_CASEFOLD) == 0
			}
		}
	}
}
