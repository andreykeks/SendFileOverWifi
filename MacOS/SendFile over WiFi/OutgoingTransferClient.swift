import Foundation
import Network
import UniformTypeIdentifiers

struct OutgoingTransferResult: Sendable {
    let skippedIndexes: [Int]
}

enum OutgoingTransferError: LocalizedError {
    case sourceUnavailable(String)
    case rejected(Int)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable(let name): AppLocalization.text("sourceUnavailable", name)
        case .rejected(let status): AppLocalization.text("transferRejected", status)
        case .malformedResponse: AppLocalization.text("malformedResponse")
        }
    }
}

@MainActor
final class OutgoingTransferClient {
func transfer(
    files: [URL],
    to recipient: DiscoveredRecipient,
    connection: NWConnection,
    senderName: String,
    progress: @escaping @MainActor (Int, Int, Int64, Int64) -> Void
) async throws -> OutgoingTransferResult {
        // URL из NSOpenPanel в sandbox несёт security-scoped bookmark. Доступ
        // нужен не только для чтения блоков, но и для предварительного SHA-256.
        let scopedURLs = files.filter { $0.startAccessingSecurityScopedResource() }
        defer { scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
        let sources = try files.map(Self.prepareSource)
        let totalSize = sources.reduce(Int64(0)) { $0 + $1.size }
        let manifest = TransferManifest(files: sources.map(\.manifest))
        defer { connection.cancel() }
        let stream = HTTPStream(connection: connection)
  let safeSenderName = senderName
    .replacingOccurrences(of: "\r", with: " ")
    .replacingOccurrences(of: "\n", with: " ")
    .trimmingCharacters(in: .whitespacesAndNewlines)
  var headers = [
    "Host": recipient.name,
    "Content-Type": "application/json",
    SendFileProtocol.tokenHeader: recipient.token,
  ]
  if !safeSenderName.isEmpty {
    headers["X-SendFile-Device-Name"] = safeSenderName
  }
        try await stream.writeRequest(method: "POST", path: "/v1/offer", headers: headers, body: try JSONEncoder().encode(manifest))
        let offer = try await stream.readResponse()
        guard offer.status == 202,
              let transferID = offer.headers["x-receive-file-transfer"],
              let acceptance = try? JSONDecoder().decode(OfferAcceptance.self, from: offer.body) else {
            throw OutgoingTransferError.rejected(offer.status)
        }

        var completed: Int64 = 0
        var skipped: [Int] = []
        for (index, source) in sources.enumerated() {
            guard acceptance.files.first(where: { $0.index == index })?.state == "uploading" else {
                completed += source.size
                continue
            }
            let handle = try FileHandle(forReadingFrom: source.url)
            defer { try? handle.close() }
            var offset: Int64 = 0
            repeat {
                let remaining = source.size - offset
                let readCount = Int(min(Int64(SendFileProtocol.chunkSize), remaining))
                let chunk = readCount == 0 ? Data() : try handle.read(upToCount: readCount) ?? Data()
                guard chunk.count == readCount else { throw OutgoingTransferError.sourceUnavailable(source.url.lastPathComponent) }
                let chunkHeaders = [
                    "Host": recipient.name,
                    "Content-Type": "application/octet-stream",
                    SendFileProtocol.tokenHeader: recipient.token,
                    "X-Receive-File-Offset": String(offset),
                ]
                try await stream.writeRequest(method: "PATCH", path: "/v1/transfers/\(transferID)/files/\(index)", headers: chunkHeaders, body: chunk)
                let response = try await stream.readResponse()
                if response.status == 422 { skipped.append(index); break }
                guard response.status == 204,
                      let next = response.headers["x-receive-file-next-offset"].flatMap(Int64.init), next == offset + Int64(chunk.count) else {
                    throw OutgoingTransferError.rejected(response.status)
                }
                offset = next
                progress(index + 1, sources.count, completed + offset, totalSize)
            } while offset < source.size
            completed += source.size
        }
        try await stream.writeRequest(method: "POST", path: "/v1/transfers/\(transferID)/complete", headers: ["Host": recipient.name, SendFileProtocol.tokenHeader: recipient.token], body: Data())
        let final = try await stream.readResponse()
        guard final.status == 201 || final.status == 207 else { throw OutgoingTransferError.rejected(final.status) }
        return OutgoingTransferResult(skippedIndexes: skipped)
    }

    private struct Source: Sendable {
        let url: URL
        let size: Int64
        let manifest: TransferManifestFile
    }

    private static func prepareSource(_ url: URL) throws -> Source {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .creationDateKey, .contentModificationDateKey, .contentTypeKey])
        guard values.isRegularFile == true, let fileSize = values.fileSize, fileSize >= 0 else {
            throw OutgoingTransferError.sourceUnavailable(url.lastPathComponent)
        }
        let encodedName = url.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .sendFilePathComponent) ?? url.lastPathComponent
        return Source(url: url, size: Int64(fileSize), manifest: TransferManifestFile(path: encodedName, size: String(fileSize), sha256: try SHA256File.digest(at: url), createdAt: Self.timestamp(values.creationDate), modifiedAt: Self.timestamp(values.contentModificationDate), mimeType: values.contentType?.preferredMIMEType))
    }

    private static func timestamp(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private extension CharacterSet {
    static let sendFilePathComponent = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
