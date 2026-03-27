import Foundation
import CryptoKit

// ---------------------------------------------------------------------------
// MARK: - FileHasher protocol
// ---------------------------------------------------------------------------

public protocol FileHasher: Sendable {
	var algorithmName: String { get }
	/// Compute a hex-encoded digest of the file at `url`.
	func hash(fileAt url: URL) throws -> String
}

// ---------------------------------------------------------------------------
// MARK: - SHA-256 implementation
// ---------------------------------------------------------------------------

public struct SHA256Hasher: FileHasher {

	public let algorithmName = "sha256"

	// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

	private let chunkSize: Int

	// ============================================================================
	public init(chunkSize: Int = 4 * 1024 * 1024) {
		self.chunkSize = chunkSize
	}

	// ============================================================================
	public func hash(fileAt url: URL) throws -> String {
		let handle: FileHandle
		do {
			handle = try FileHandle(forReadingFrom: url)
		} catch {
			throw AppError.fileAccess(path: url.path, underlying: error)
		}
		defer { try? handle.close() }

		var hasher = CryptoKit.SHA256()

		while true {
			let chunk: Data
			do {
				chunk = try handle.read(upToCount: chunkSize) ?? Data()
			} catch {
				throw AppError.fileAccess(path: url.path, underlying: error)
			}
			if chunk.isEmpty { break }
			hasher.update(data: chunk)
		}

		let digest = hasher.finalize()
		return digest.map { String(format: "%02x", $0) }.joined()
	}
}

// ---------------------------------------------------------------------------
// MARK: - Factory
// ---------------------------------------------------------------------------

public enum HasherFactory {

	// ============================================================================
	public static func make(for algorithmName: String) throws -> any FileHasher {
		switch algorithmName.lowercased() {
		case "sha256":
			return SHA256Hasher()
		default:
			throw AppError.unsupportedHashAlgorithm(algorithmName)
		}
	}
}
