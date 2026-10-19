import Combine
import Foundation
import Network
import UIKit

/// Keeps a confirmed transfer eligible for the limited background execution
/// time granted by iOS. It neither starts background networking nor keeps a
/// listener advertised after the UI becomes inactive.
final class IOSBackgroundTransferLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        guard identifier == .invalid else { return }
        identifier = UIApplication.shared.beginBackgroundTask(withName: "SendFile transfer") { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }

    deinit { end() }
}

actor IncomingTransferServer {
    typealias Approval = @Sendable (PendingIncomingOffer, String?) async -> Bool
    typealias ProgressHandler = @Sendable (IncomingTransferProgress) async -> Void
    typealias CompletionHandler = @Sendable (IncomingTransferResult) async -> Void

    private let store: ReceiverTransferStore
    private let approval: Approval
    private let progressHandler: ProgressHandler
    private let completionHandler: CompletionHandler

    init(store: ReceiverTransferStore, approval: @escaping Approval, progress: @escaping ProgressHandler, completion: @escaping CompletionHandler) {
        self.store = store
        self.approval = approval
        progressHandler = progress
        completionHandler = completion
    }

    func serve(_ connection: NWConnection, expectedToken: String) async {
        let stream = HTTPStream(connection: connection)
        do {
            while true {
                let request = try await stream.readRequest()
                let response = try await handle(request, expectedToken: expectedToken)
                try await stream.writeResponse(response)
            }
        } catch {
            connection.cancel()
        }
    }

    private func handle(_ request: HTTPRequestMessage, expectedToken: String) async throws -> HTTPResponseMessage {
        guard request.headers[SendFileProtocol.tokenHeader.lowercased()] == expectedToken else {
            return .empty(401, "Invalid Session Token")
        }
        switch (request.method, request.path) {
        case ("POST", "/v1/offer"):
            let manifest: TransferManifest
            do { manifest = try JSONDecoder().decode(TransferManifest.self, from: request.body) }
            catch { return .empty(400, "Bad Request") }
            do {
                let offer = try await store.prepareOffer(manifest)
                guard await approval(offer, request.headers["x-sendfile-device-name"]) else {
                    await store.rejectOffer(id: offer.id)
                    return .empty(403, "Declined")
                }
                let accepted = try await store.acceptOffer(id: offer.id)
                var headers = ["X-Receive-File-Transfer": offer.id, "Content-Type": "application/json"]
                headers["Content-Type"] = "application/json"
                return HTTPResponseMessage(status: 202, reason: "Offer Accepted", headers: headers, body: try JSONEncoder().encode(OfferAcceptance(files: accepted.files)))
            } catch ReceiverError.busy {
                return .empty(409, "Another Offer Is Pending")
            } catch ReceiverError.insufficientSpace {
                return .empty(507, "Insufficient Storage")
            } catch {
                return .empty(400, "Bad Request")
            }

        case ("PATCH", let path):
            guard let route = Self.fileRoute(path),
                  let offsetText = request.headers["x-receive-file-offset"], let offset = Int64(offsetText) else {
                return .empty(400, "Bad Request")
            }
            do {
                let next = try await store.appendChunk(transferID: route.transferID, index: route.index, offset: offset, data: request.body)
                await progressHandler(try await store.progress(transferID: route.transferID))
                return .empty(204, "Chunk Received", headers: ["X-Receive-File-Next-Offset": String(next)])
            } catch ReceiverError.offsetMismatch(let next) {
                return .empty(409, "Offset Mismatch", headers: ["X-Receive-File-Next-Offset": String(next)])
            } catch ReceiverError.notFound {
                return .empty(410, "Transfer Expired")
            } catch {
                return .empty(422, "File Changed")
            }

        case ("POST", let path) where path.hasSuffix("/complete"):
            guard let transferID = Self.completeRoute(path) else { return .empty(400, "Bad Request") }
            do {
                let result = try await store.complete(transferID: transferID)
                await completionHandler(result)
                if result.skippedFileCount == 0 { return .empty(201, "Received") }
                let body = try JSONSerialization.data(withJSONObject: ["skipped": result.skippedFileCount])
                return HTTPResponseMessage(status: 207, reason: "Transfer Completed With Skipped Files", headers: ["Content-Type": "application/json"], body: body)
            } catch ReceiverError.incomplete {
                return .empty(409, "Transfer Incomplete")
            } catch {
                return .empty(410, "Transfer Expired")
            }

        default:
            return .empty(400, "Bad Request")
        }
    }

    private static func fileRoute(_ path: String) -> (transferID: String, index: Int)? {
        let parts = path.split(separator: "/")
        guard parts.count == 5, parts[0] == "v1", parts[1] == "transfers", parts[3] == "files", let index = Int(parts[4]) else { return nil }
        return (String(parts[2]), index)
    }

    private static func completeRoute(_ path: String) -> String? {
        let parts = path.split(separator: "/")
        guard parts.count == 4, parts[0] == "v1", parts[1] == "transfers", parts[3] == "complete" else { return nil }
        return String(parts[2])
    }
}

@MainActor
final class ReceiverSessionCoordinator: ObservableObject {
    @Published private(set) var pendingOffer: PendingIncomingOffer?
    @Published private(set) var pendingPairingCode: String?
    @Published private(set) var progress: IncomingTransferProgress?
    @Published private(set) var result: IncomingTransferResult?

    private let store = ReceiverTransferStore()
    private var decision: CheckedContinuation<Bool, Never>?
    private var pairingDecision: CheckedContinuation<Bool, Never>?
    private var pendingPeerFingerprint: String?
    private var activePeerFingerprint: String?
    private lazy var server = IncomingTransferServer(
        store: store,
        approval: { [weak self] offer, senderName in
            guard let self else { return false }
            return await self.requestApproval(for: offer, senderName: senderName)
        },
        progress: { [weak self] progress in await self?.update(progress: progress) },
        completion: { [weak self] result in await self?.complete(result: result) }
    )

    func handle(_ connection: NWConnection, token: String, pairingCode: String?, peerFingerprint: String?) {
        Task {
            activePeerFingerprint = peerFingerprint
            if let peerFingerprint, TrustedDeviceStore.contains(peerFingerprint) {
                let backgroundLease = IOSBackgroundTransferLease()
                backgroundLease.begin()
                defer { backgroundLease.end() }
                await server.serve(connection, expectedToken: token)
                return
            }
            pendingPeerFingerprint = peerFingerprint
            guard let pairingCode, await requestPairing(for: pairingCode) else {
                connection.cancel()
                return
            }
            let backgroundLease = IOSBackgroundTransferLease()
            backgroundLease.begin()
            defer { backgroundLease.end() }
            await server.serve(connection, expectedToken: token)
        }
    }

    func accept() { resolve(true) }
    func decline() { resolve(false) }
    func acceptPairing() { resolvePairing(true) }
    func declinePairing() { resolvePairing(false) }

    /// A completed result belongs to the previous receive operation. It must
    /// not stay visible once the user explicitly starts a new listener.
    /// Incomplete transfers have no result and therefore remain untouched.
    func clearCompletedResult() {
        result = nil
        progress = nil
    }

    private func requestApproval(for offer: PendingIncomingOffer, senderName: String?) async -> Bool {
        if let activePeerFingerprint {
            TrustedDeviceStore.trust(activePeerFingerprint, name: senderName)
        }
        return await withCheckedContinuation { continuation in
            progress = nil
            result = nil
            pendingOffer = offer
            decision = continuation
        }
    }

    private func resolve(_ value: Bool) {
        pendingOffer = nil
        decision?.resume(returning: value)
        decision = nil
    }

    private func requestPairing(for code: String) async -> Bool {
        await withCheckedContinuation { continuation in
            pendingPairingCode = code
            pairingDecision = continuation
        }
    }

    private func resolvePairing(_ value: Bool) {
        pendingPairingCode = nil
        pendingPeerFingerprint = nil
        pairingDecision?.resume(returning: value)
        pairingDecision = nil
    }

    private func update(progress: IncomingTransferProgress) {
        self.progress = progress
    }

    private func complete(result: IncomingTransferResult) {
        progress = nil
        self.result = result
    }
}
