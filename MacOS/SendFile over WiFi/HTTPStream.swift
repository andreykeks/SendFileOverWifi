import Foundation
import Network

/// Последовательный HTTP/1.1 поток. Протокол v1 не использует HTTP/2,
/// chunked-encoding или конвейеризацию, поэтому один экземпляр обслуживает
/// одну TLS-сессию и читает запросы строго по порядку.
actor HTTPStream {
    private let connection: NWConnection
    private var buffered = Data()

    init(connection: NWConnection) {
        self.connection = connection
    }

    func readRequest() async throws -> HTTPRequestMessage {
        let headerData = try await readHeader()
        guard let header = String(data: headerData, encoding: .utf8) else {
            throw TransferProtocolError.malformedRequest
        }
        let lines = header.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first?.split(separator: " "), requestLine.count == 3 else {
            throw TransferProtocolError.malformedRequest
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else { throw TransferProtocolError.malformedRequest }
            headers[String(line[..<separator]).lowercased()] = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        }
        let contentLength = try contentLength(headers)
        let body = try await readExactly(contentLength)
        return HTTPRequestMessage(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: body)
    }

    func writeResponse(_ response: HTTPResponseMessage) async throws {
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "keep-alive"
        var wire = Data("HTTP/1.1 \(response.status) \(response.reason)\r\n".utf8)
        for (name, value) in headers { wire.append(Data("\(name): \(value)\r\n".utf8)) }
        wire.append(Data("\r\n".utf8))
        wire.append(response.body)
        try await send(wire)
    }

    func writeRequest(method: String, path: String, headers: [String: String], body: Data) async throws {
        var combined = headers
        combined["Content-Length"] = String(body.count)
        var wire = Data("\(method) \(path) HTTP/1.1\r\n".utf8)
        for (name, value) in combined { wire.append(Data("\(name): \(value)\r\n".utf8)) }
        wire.append(Data("\r\n".utf8))
        wire.append(body)
        try await send(wire)
    }

    func readResponse() async throws -> HTTPResponseMessage {
        let headerData = try await readHeader()
        guard let header = String(data: headerData, encoding: .utf8) else { throw TransferProtocolError.malformedRequest }
        let lines = header.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let statusLine = lines.first?.split(separator: " ", maxSplits: 2), statusLine.count >= 2,
              let status = Int(statusLine[1]) else { throw TransferProtocolError.malformedRequest }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else { throw TransferProtocolError.malformedRequest }
            headers[String(line[..<separator]).lowercased()] = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        }
        return HTTPResponseMessage(
            status: status,
            reason: statusLine.count == 3 ? String(statusLine[2]) : "",
            headers: headers,
            body: try await readExactly(try contentLength(headers))
        )
    }

    private func readHeader() async throws -> Data {
        let marker = Data("\r\n\r\n".utf8)
        while buffered.range(of: marker) == nil {
            buffered.append(try await receive())
            if buffered.count > 64 * 1024 { throw TransferProtocolError.malformedRequest }
        }
        let range = buffered.range(of: marker)!
        let header = buffered[..<range.lowerBound]
        buffered.removeSubrange(..<range.upperBound)
        return Data(header)
    }

    private func readExactly(_ count: Int) async throws -> Data {
        guard count >= 0 else { throw TransferProtocolError.invalidContentLength }
        while buffered.count < count { buffered.append(try await receive()) }
        let result = buffered.prefix(count)
        buffered.removeFirst(count)
        return Data(result)
    }

    private func contentLength(_ headers: [String: String]) throws -> Int {
        guard let value = headers["content-length"], let length = Int(value), length >= 0 else {
            throw TransferProtocolError.invalidContentLength
        }
        return length
    }

    private func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if complete { continuation.resume(throwing: TransferProtocolError.unexpectedEndOfStream) }
                else { continuation.resume(throwing: TransferProtocolError.unexpectedEndOfStream) }
            }
        }
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
}

