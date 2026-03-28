import Foundation

// ---------------------------------------------------------------------------
// MARK: - ProcessLock
//
// Advisory PID lock file to prevent concurrent runs. The lock file stores the
// PID of the owning process. On acquire, if a stale lock is found (the
// recorded PID is no longer running), it is automatically replaced.
// ---------------------------------------------------------------------------

public final class ProcessLock {

	private let lockURL: URL
	private var acquired = false

	// ============================================================================
	public init(directory: URL) {
		self.lockURL = directory.appendingPathComponent("raid-integrity-monitor.lock")
	}

	// ============================================================================
	/// Try to acquire the lock. Returns a description of the blocking process
	/// on failure, or `nil` on success.
	public func tryAcquire() -> String? {
		let fileManager = FileManager.default
		let myPID = ProcessInfo.processInfo.processIdentifier

		// Check for existing lock
		if let data = fileManager.contents(atPath: lockURL.path),
		   let contents = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
		   let existingPID = Int32(contents) {

			if isProcessRunning(pid: existingPID) {
				return "Another instance is already running (PID \(existingPID))"
			}
			// Stale lock — previous run crashed or was killed
		}

		// Write our PID
		do {
			try "\(myPID)\n".write(to: lockURL, atomically: true, encoding: .utf8)
			acquired = true
			return nil
		} catch {
			return "Could not create lock file: \(error.localizedDescription)"
		}
	}

	// ============================================================================
	public func release() {
		guard acquired else { return }
		try? FileManager.default.removeItem(at: lockURL)
		acquired = false
	}

	// ============================================================================
	deinit {
		release()
	}

	// MARK: - Private

	// ============================================================================
	/// Check whether a process with the given PID is currently running.
	private func isProcessRunning(pid: Int32) -> Bool {
		// kill(pid, 0) returns 0 if the process exists and we have permission
		// to signal it. ESRCH means no such process.
		return kill(pid, 0) == 0 || errno != ESRCH
	}
}
