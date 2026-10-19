import Foundation

enum SendFileProtocol {
    nonisolated static let chunkSize = 4 * 1024 * 1024
    nonisolated static let serviceType = "_sendfile._tcp"
    nonisolated static let tokenHeader = "X-Receive-File-Token"
}

nonisolated struct TransferManifest: Codable, Sendable {
    let files: [TransferManifestFile]
}

nonisolated struct TransferManifestFile: Codable, Sendable, Identifiable {
    let path: String
    let size: String
    let sha256: String
    let createdAt: String?
    let modifiedAt: String?
    let mimeType: String?

    var id: String { path }
    nonisolated var byteCount: Int64? { Int64(size) }
}

nonisolated struct OfferAcceptance: Codable, Sendable {
    let files: [OfferAcceptanceFile]
}

nonisolated struct OfferAcceptanceFile: Codable, Sendable {
    let index: Int
    let path: String
    let state: String
}

nonisolated struct TransferStatusResponse: Codable, Sendable {
    let state: String
    let files: [TransferStatusFile]
}

nonisolated struct TransferStatusFile: Codable, Sendable {
    let index: Int
    let size: String
    let nextOffset: String
    let state: String
}

nonisolated struct HTTPRequestMessage: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

nonisolated struct HTTPResponseMessage: Sendable {
    let status: Int
    let reason: String
    let headers: [String: String]
    let body: Data

    nonisolated static func empty(_ status: Int, _ reason: String, headers: [String: String] = [:]) -> Self {
        Self(status: status, reason: reason, headers: headers, body: Data())
    }
}

enum TransferProtocolError: LocalizedError {
    case malformedRequest
    case unexpectedEndOfStream
    case invalidContentLength
    case connection(String)

    var errorDescription: String? {
        switch self {
        case .malformedRequest: AppLocalization.text("malformedRequest")
        case .unexpectedEndOfStream: AppLocalization.text("connectionClosed")
        case .invalidContentLength: AppLocalization.text("invalidContentLength")
        case .connection(let message): message
        }
    }
}
