import Combine
import Foundation
import Network
import Security
import CryptoKit

struct DiscoveredRecipient: Identifiable, Equatable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
    let token: String
}

/// Bonjour и TLS-транспорт. HTTP-обработчик назначается отдельно, чтобы
/// передача не была связана с жизненным циклом SwiftUI-экрана.
@MainActor
final class LocalNetworkService: ObservableObject {
    @Published private(set) var recipients: [DiscoveredRecipient] = []
    @Published private(set) var receiverIsRunning = false
    @Published private(set) var lastError: String?

    var onIncomingConnection: ((NWConnection, String, String?, String?) -> Void)?

    private let queue = DispatchQueue(label: "com.ao.sendfileoverwifi.network")
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var receiverToken: String?
    private var identity: SecIdentity?

    func startReceiver(name: String) {
        stopReceiver()
        do {
            let token = Self.randomToken()
            let advertisedToken = token
            let listener = try NWListener(using: try tlsParameters())
            listener.service = NWListener.Service(
                name: name.isEmpty ? nil : name,
                type: "_sendfile._tcp",
                domain: nil,
                txtRecord: NWTXTRecord(["v": "1", "t": token])
            )
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                var delivered = false
                connection.stateUpdateHandler = { state in
                    guard case .ready = state, !delivered else { return }
                    delivered = true
                    let code = self.pairingCode(for: connection)
                    let fingerprint = self.peerFingerprint(for: connection)
                    Task { @MainActor [weak self] in
                        self?.onIncomingConnection?(connection, advertisedToken, code, fingerprint)
                    }
                }
                connection.start(queue: self.queue)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let service = self else { return }
                Task { @MainActor in
                    switch state {
                    case .ready:
                        service.receiverIsRunning = true
                        service.lastError = nil
                    case .failed(let error):
                        service.receiverIsRunning = false
                        service.lastError = error.localizedDescription
                    case .cancelled:
                        service.receiverIsRunning = false
                    default:
                        break
                    }
                }
            }
            receiverToken = token
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stopReceiver() {
        listener?.cancel()
        listener = nil
        receiverToken = nil
        receiverIsRunning = false
    }

    func startBrowsing() {
        stopBrowsing()
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_sendfile._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let recipients = results.compactMap(Self.recipient(from:))
            Task { @MainActor [weak self] in self?.recipients = recipients.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
        }
        browser.stateUpdateHandler = { [weak self] state in
            guard case .failed(let error) = state else { return }
            Task { @MainActor [weak self] in self?.lastError = error.localizedDescription }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        recipients = []
    }

    func connect(to recipient: DiscoveredRecipient, completion: @escaping (Result<NWConnection, Error>) -> Void) {
        let parameters: NWParameters
        do { parameters = try tlsParameters() }
        catch { completion(.failure(error)); return }
        let connection = NWConnection(to: recipient.endpoint, using: parameters)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                completion(.success(connection))
            case .failed(let error):
                completion(.failure(error))
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func connect(to recipient: DiscoveredRecipient) async throws -> NWConnection {
        try await withCheckedThrowingContinuation { continuation in
            connect(to: recipient) { result in continuation.resume(with: result) }
        }
    }

    nonisolated func pairingCode(for connection: NWConnection) -> String? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            return nil
        }
        let label = "EXPORTER-SendFile-v1-SAS"
        guard let secret = sec_protocol_metadata_create_secret(
            metadata.securityProtocolMetadata,
            label.utf8.count,
            label,
            32
        ) else { return nil }
        let dispatchData = secret as DispatchData
        let bytes: Data = dispatchData.withUnsafeBytes { (buffer: UnsafePointer<UInt8>) in
            Data(bytes: buffer, count: dispatchData.count)
        }
        guard bytes.count >= 3 else { return nil }
        let first = UInt32(bytes[0]) << 12
        let second = UInt32(bytes[1]) << 4
        let third = UInt32(bytes[2]) >> 4
        let value = first | second | third
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        return String([
            alphabet[Int((value >> 15) & 31)],
            alphabet[Int((value >> 10) & 31)],
            alphabet[Int((value >> 5) & 31)],
            alphabet[Int(value & 31)],
        ])
    }

    nonisolated func peerFingerprint(for connection: NWConnection) -> String? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
              let keyData = sec_protocol_metadata_copy_peer_public_key(metadata.securityProtocolMetadata) else { return nil }
        let dispatchData = keyData as DispatchData
        let data: Data = dispatchData.withUnsafeBytes { buffer in
            Data(bytes: buffer, count: dispatchData.count)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func tlsParameters() throws -> NWParameters {
        if identity == nil { identity = try DeviceIdentity.loadOrCreate() }
        guard let identity else { throw DeviceIdentity.IdentityError.identity }
        let options = NWProtocolTLS.Options()
        let securityOptions = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(securityOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(securityOptions, .TLSv13)
        guard let localIdentity = sec_identity_create(identity) else {
            fatalError("Unable to create TLS identity")
        }
        sec_protocol_options_set_local_identity(securityOptions, localIdentity)
        sec_protocol_options_set_peer_authentication_required(securityOptions, true)
        // Самоподписанные сертификаты проверяются после рукопожатия по
        // сохранённому отпечатку и SAS, а не по системному центру сертификации.
        sec_protocol_options_set_verify_block(securityOptions, { _, _, complete in complete(true) }, queue)
        let parameters = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
        parameters.includePeerToPeer = true
        return parameters
    }

    nonisolated private static func recipient(from result: NWBrowser.Result) -> DiscoveredRecipient? {
        guard case let .service(name, _, _, _) = result.endpoint,
              case let .bonjour(record) = result.metadata,
              case let .string(token)? = record.getEntry(for: "t"),
              !token.isEmpty else { return nil }
        return DiscoveredRecipient(id: result.endpoint.debugDescription, name: name, endpoint: result.endpoint, token: token)
    }

    nonisolated private static func randomToken() -> String {
        let bytes = Data((0..<8).map { _ in UInt8.random(in: .min ... .max) })
        return bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct TrustedDevice: Codable, Identifiable, Sendable {
    let fingerprint: String
    var name: String
    var id: String { fingerprint }
}

enum TrustedDeviceStore {
    private static let recordsKey = "trustedDeviceRecordsV1"

    nonisolated static func records() -> [TrustedDevice] {
        guard let data = UserDefaults.standard.data(forKey: recordsKey),
              let records = try? JSONDecoder().decode([TrustedDevice].self, from: data) else {
            return (UserDefaults.standard.stringArray(forKey: "trustedDevicePublicKeyFingerprints") ?? []).map {
                TrustedDevice(fingerprint: $0, name: AppLocalization.text("unnamedDevice", String($0.prefix(8))))
            }
        }
        return records.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    nonisolated static func contains(_ fingerprint: String) -> Bool {
        records().contains { $0.fingerprint == fingerprint }
    }

    nonisolated static func trust(_ fingerprint: String, name: String? = nil) {
        var records = records()
        let value = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = records.firstIndex(where: { $0.fingerprint == fingerprint }) {
            if let value, !value.isEmpty { records[index].name = value }
        } else {
            records.append(TrustedDevice(fingerprint: fingerprint, name: value?.isEmpty == false ? value! : AppLocalization.text("unnamedDevice", String(fingerprint.prefix(8)))))
        }
        if let data = try? JSONEncoder().encode(records) { UserDefaults.standard.set(data, forKey: recordsKey) }
    }

    nonisolated static func remove(_ fingerprint: String) {
        let records = records().filter { $0.fingerprint != fingerprint }
        if let data = try? JSONEncoder().encode(records) { UserDefaults.standard.set(data, forKey: recordsKey) }
    }
}
