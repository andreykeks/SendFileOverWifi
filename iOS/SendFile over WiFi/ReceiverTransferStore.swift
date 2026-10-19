import CryptoKit
import Foundation

struct PendingIncomingOffer: Sendable, Identifiable {
    let id: String
    let fileCount: Int
    let totalSize: Int64
}

struct IncomingTransferProgress: Sendable {
    let currentFile: Int
    let fileCount: Int
    let transferredBytes: Int64
    let totalBytes: Int64
}

struct IncomingTransferResult: Sendable, Equatable {
    let receivedFileCount: Int
    let totalSize: Int64
    let skippedFileCount: Int
}

actor ReceiverTransferStore {
    private struct FileState: Sendable {
        let manifest: TransferManifestFile
        let destinationURL: URL
        let stagingURL: URL
        var offset: Int64
        var state: String
    }

    private struct TransferState: Sendable {
        let id: String
        let root: URL
        let totalBytes: Int64
        var files: [FileState]
    }

    private let fileManager = FileManager.default
    private var active: TransferState?

    func prepareOffer(_ manifest: TransferManifest) throws -> PendingIncomingOffer {
        guard active == nil, !manifest.files.isEmpty else { throw ReceiverError.busy }
        var total: Int64 = 0
        var states: [FileState] = []
        let id = Self.randomIdentifier()
        let root = try stagingDirectory(for: id)
        let destinationRoot = try receivedDirectory()

        for entry in manifest.files {
            guard let size = entry.byteCount, size >= 0, Self.isSHA256(entry.sha256) else {
                throw ReceiverError.invalidManifest
            }
            let relativePath = try Self.decodeRelativePath(entry.path)
            total = try Self.adding(total, size)
            let destination = try uniqueDestination(relativePath: relativePath, root: destinationRoot, digest: entry.sha256)
            let staging = root.appendingPathComponent(relativePath, isDirectory: false)
            try fileManager.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
            fileManager.createFile(atPath: staging.path, contents: nil)
            states.append(FileState(manifest: entry, destinationURL: destination, stagingURL: staging, offset: 0, state: "uploading"))
        }
        try reserveSpace(total)
        active = TransferState(id: id, root: root, totalBytes: total, files: states)
        return PendingIncomingOffer(id: id, fileCount: states.count, totalSize: total)
    }

    func acceptOffer(id: String) throws -> OfferAcceptance {
        guard let active, active.id == id else { throw ReceiverError.notFound }
        return OfferAcceptance(files: active.files.enumerated().map {
            OfferAcceptanceFile(index: $0.offset, path: $0.element.manifest.path, state: $0.element.state)
        })
    }

    func rejectOffer(id: String) {
        guard let active, active.id == id else { return }
        try? fileManager.removeItem(at: active.root)
        self.active = nil
    }

    func appendChunk(transferID: String, index: Int, offset: Int64, data: Data) throws -> Int64 {
        guard var transfer = active, transfer.id == transferID,
              transfer.files.indices.contains(index) else { throw ReceiverError.notFound }
        var file = transfer.files[index]
        guard file.state == "uploading", offset == file.offset,
              let expectedSize = file.manifest.byteCount,
              Int64(data.count) <= expectedSize - offset else { throw ReceiverError.offsetMismatch(file.offset) }
        if offset + Int64(data.count) < expectedSize, data.count != SendFileProtocol.chunkSize {
            throw ReceiverError.invalidChunk
        }
        let handle = try FileHandle(forWritingTo: file.stagingURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
        try handle.synchronize()
        file.offset += Int64(data.count)
        if file.offset == expectedSize {
            let digest = try SHA256File.digest(at: file.stagingURL)
            if digest == file.manifest.sha256 {
                try fileManager.createDirectory(at: file.destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: file.stagingURL, to: file.destinationURL)
                applyDates(from: file.manifest, to: file.destinationURL)
                file.state = "received"
            } else {
                try? fileManager.removeItem(at: file.stagingURL)
                file.state = "skipped"
            }
        }
        transfer.files[index] = file
        active = transfer
        return file.offset
    }

    func progress(transferID: String) throws -> IncomingTransferProgress {
        guard let transfer = active, transfer.id == transferID else { throw ReceiverError.notFound }
        let current = (transfer.files.firstIndex { $0.state == "uploading" } ?? max(transfer.files.count - 1, 0)) + 1
        let transferred = transfer.files.reduce(Int64(0)) { $0 + $1.offset }
        return IncomingTransferProgress(currentFile: current, fileCount: transfer.files.count, transferredBytes: transferred, totalBytes: transfer.totalBytes)
    }

    func complete(transferID: String) throws -> IncomingTransferResult {
        guard let transfer = active, transfer.id == transferID else { throw ReceiverError.notFound }
        guard transfer.files.allSatisfy({ $0.state == "received" || $0.state == "skipped" }) else {
            throw ReceiverError.incomplete
        }
        let skipped = transfer.files.enumerated().compactMap { $0.element.state == "skipped" ? $0.offset : nil }
        try? fileManager.removeItem(at: transfer.root)
        active = nil
        return IncomingTransferResult(receivedFileCount: transfer.files.count - skipped.count, totalSize: transfer.totalBytes, skippedFileCount: skipped.count)
    }

    private func receivedDirectory() throws -> URL {
        let documents = try fileManager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = documents.appendingPathComponent("Received Files", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func applyDates(from manifest: TransferManifestFile, to url: URL) {
        guard UserDefaults.standard.object(forKey: "preserveDates") as? Bool ?? false else { return }
        // Creation time is unavailable on some Apple volumes. Apply each value
        // independently so that failure to set it never loses modifiedAt.
        if let date = Self.date(manifest.createdAt) {
            try? fileManager.setAttributes([.creationDate: date], ofItemAtPath: url.path)
        }
        if let date = Self.date(manifest.modifiedAt) {
            try? fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private func stagingDirectory(for id: String) throws -> URL {
        let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("SendFileTransfers/\(id)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func reserveSpace(_ required: Int64) throws {
        let root = try receivedDirectory()
        let values = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage, available >= required else {
            throw ReceiverError.insufficientSpace
        }
    }

    private func uniqueDestination(relativePath: String, root: URL, digest: String) throws -> URL {
        let candidate = root.appendingPathComponent(relativePath)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }
        if try SHA256File.digest(at: candidate) == digest { return candidate }
        let directory = candidate.deletingLastPathComponent()
        let extensionPart = candidate.pathExtension
        let stem = candidate.deletingPathExtension().lastPathComponent
        var number = 2
        while true {
            let name = extensionPart.isEmpty ? "\(stem) (\(number))" : "\(stem) (\(number)).\(extensionPart)"
            let alternative = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: alternative.path) { return alternative }
            number += 1
        }
    }

    private static func decodeRelativePath(_ encodedPath: String) throws -> String {
        guard !encodedPath.isEmpty, !encodedPath.hasPrefix("/"), !encodedPath.contains("\\") else { throw ReceiverError.invalidManifest }
        let segments = encodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.isEmpty else { throw ReceiverError.invalidManifest }
        var decoded: [String] = []
        for segment in segments {
            guard !segment.isEmpty, let value = String(segment).removingPercentEncoding,
                  !value.isEmpty, value != ".", value != "..", !value.contains("/") && !value.contains("\\") else {
                throw ReceiverError.invalidManifest
            }
            decoded.append(value)
        }
        return decoded.joined(separator: "/")
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func adding(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw ReceiverError.invalidManifest }
        return result
    }

    private static func randomIdentifier() -> String { UUID().uuidString.lowercased() }
}

enum ReceiverError: LocalizedError {
    case busy, invalidManifest, insufficientSpace, notFound, offsetMismatch(Int64), invalidChunk, incomplete

    var errorDescription: String? {
        switch self {
        case .busy: AppLocalization.text("transferBusy")
        case .invalidManifest: AppLocalization.text("invalidManifest")
        case .insufficientSpace: AppLocalization.text("insufficientSpace")
        case .notFound: AppLocalization.text("transferNotFound")
        case .offsetMismatch: AppLocalization.text("offsetMismatch")
        case .invalidChunk: AppLocalization.text("invalidChunk")
        case .incomplete: AppLocalization.text("transferIncomplete")
        }
    }
}

enum SHA256File {
    nonisolated static func digest(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
