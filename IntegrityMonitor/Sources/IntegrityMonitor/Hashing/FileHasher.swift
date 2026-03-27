import Foundation
import CryptoKit

// ---------------------------------------------------------------------------
// MARK: - FileHasher protocol
// ---------------------------------------------------------------------------

/// Reports bytes hashed so far and total file size.
public typealias HashProgressHandler = @Sendable (Int64, Int64) -> Void

public protocol FileHasher: Sendable {
	var algorithmName: String { get }
	/// Compute a hex-encoded digest of the file at `url`.
	func hash(fileAt url: URL) throws -> String
	/// Compute a hex-encoded digest, reporting chunk-level progress.
	func hash(
		fileAt url: URL,
		onProgress: HashProgressHandler?
	) throws -> String
}

// Default: delegate to the no-progress version.
public extension FileHasher {

	// ============================================================================
	func hash(
		fileAt url: URL,
		onProgress: HashProgressHandler?
	) throws -> String {
		try hash(fileAt: url)
	}
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
		try hash(fileAt: url, onProgress: nil)
	}

	// ============================================================================
	public func hash(
		fileAt url: URL,
		onProgress: HashProgressHandler?
	) throws -> String {
		let handle: FileHandle
		do {
			handle = try FileHandle(forReadingFrom: url)
		} catch {
			throw AppError.fileAccess(path: url.path, underlying: error)
		}
		defer { try? handle.close() }

		let totalSize: Int64 = Int64(
			(try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
		)
		var bytesProcessed: Int64 = 0
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
			bytesProcessed += Int64(chunk.count)
			onProgress?(bytesProcessed, totalSize)
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
