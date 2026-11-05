import Foundation
import Network
import os

/// The pairing endpoint (docs/specs/mobile-pairing.md): a plain HTTP
/// listener on every interface, on a port the system picks, that lives
/// while Pair iPhone… shows its code. It answers only what proves the code
/// (an HMAC under it, `MobilePairingOffer.proof`):
///
/// - `GET /hello?proof=…` → `{"v":1,"name":…}`, which the phone asks every
///   address the offer lists to find one that reaches this Mac;
/// - `POST /pair` with `{"v":1,"key":…,"name":…,"proof":…}` → held until
///   `decide` answers (you allow or deny it on the Mac), then
///   `{"v":1,"name":…,"user":…}`, 403 `declined` or 500 `not_added`.
///
/// One pairing at a time (409 `busy`), and the code is spent by the first
/// answer (410 `used`) or by 10 wrong proofs. A request is at most 16 KiB
/// and must arrive within 10 s; at most 8 connections at once.
final class MobilePairingListener: Sendable {
    struct Request: Equatable, Sendable {
        var key: SSHPublicKeyLine
        var name: String
    }

    enum Answer: Equatable, Sendable {
        case added
        case declined
        case failed(String)
    }

    static let maximumRequestBytes = 16 * 1024
    static let maximumFailedProofs = 10
    static let maximumConnections = 8
    static let readTimeout: Duration = .seconds(10)

    private struct State {
        var listener: NWListener?
        var connections = 0
        var deciding = false
        var spent = false
        var failedProofs = 0
    }

    private let code: Data
    private let macName: String
    private let user: String
    private let decide: @Sendable (Request) async -> Answer
    private let queue = DispatchQueue(label: "cherry.mobile-pairing")
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(code: Data, macName: String, user: String, decide: @escaping @Sendable (Request) async -> Answer) {
        self.code = code
        self.macName = macName
        self.user = user
        self.decide = decide
    }

    /// Listens on every interface; returns the port.
    func start() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        state.withLock { $0.listener = listener }
        let resumed = OSAllocatedUnfairLock(initialState: false)
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                let result: Result<UInt16, Error>? = switch state {
                case .ready: listener.port.map { .success($0.rawValue) } ?? .failure(CocoaError(.featureUnsupported))
                case .failed(let error): .failure(error)
                case .cancelled: .failure(CancellationError())
                default: nil
                }
                guard let result, resumed.withLock({ resumed in
                    defer { resumed = true }
                    return !resumed
                }) else { return }
                continuation.resume(with: result)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        state.withLock { state in
            state.listener?.cancel()
            state.listener = nil
        }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let admitted = state.withLock { state in
            guard state.connections < Self.maximumConnections else { return false }
            state.connections += 1
            return true
        }
        guard admitted else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        Task {
            let response: Response
            do {
                response = await handle(try await readRequest(connection))
            } catch {
                response = .error(400, "bad_request")
            }
            await send(response, on: connection)
            connection.cancel()
            state.withLock { $0.connections -= 1 }
        }
    }

    /// The request, read within `readTimeout`: after it the connection is
    /// cancelled, which ends the read.
    private func readRequest(_ connection: NWConnection) async throws -> HTTPRequest {
        try await withThrowingTaskGroup(of: HTTPRequest?.self) { group in
            group.addTask {
                var buffer = Data()
                while true {
                    if let request = try HTTPRequest(parsing: buffer, limit: Self.maximumRequestBytes) {
                        return request
                    }
                    let chunk = try await Self.receive(connection)
                    guard !chunk.isEmpty else { throw HTTPRequest.Malformed() }
                    buffer.append(chunk)
                }
            }
            group.addTask {
                try await Task.sleep(for: Self.readTimeout)
                connection.cancel()
                return nil
            }
            defer { group.cancelAll() }
            guard let request = try await group.next() ?? nil else { throw HTTPRequest.Malformed() }
            return request
        }
    }

    private static func receive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }
        }
    }

    private func send(_ response: Response, on connection: NWConnection) async {
        let head = "HTTP/1.1 \(response.status) \(response.reason)\r\nContent-Type: application/json\r\nContent-Length: \(response.json.count)\r\nConnection: close\r\n\r\n"
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: Data(head.utf8) + response.json, completion: .contentProcessed { _ in continuation.resume() })
        }
    }

    // MARK: Requests

    private struct Response: Sendable {
        var status: Int
        var json: Data

        init(status: Int, body: [String: Any]) {
            self.status = status
            json = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8)
        }

        var reason: String {
            switch status {
            case 200: "OK"
            case 400: "Bad Request"
            case 401: "Unauthorized"
            case 403: "Forbidden"
            case 404: "Not Found"
            case 409: "Conflict"
            case 410: "Gone"
            default: "Internal Server Error"
            }
        }

        static func error(_ status: Int, _ code: String, message: String? = nil) -> Response {
            Response(status: status, body: ["error": code].merging(message.map { ["message": $0] } ?? [:]) { a, _ in a })
        }
    }

    private struct PairBody: Decodable {
        var v: Int
        var key: String
        var name: String
        var proof: String
    }

    private func handle(_ request: HTTPRequest) async -> Response {
        switch (request.method, request.path) {
        case ("GET", "/hello"):
            guard let proof = request.query["proof"],
                  MobilePairingOffer.isProof(proof, of: MobilePairingOffer.helloMessage, code: code)
            else { return .error(404, "not_found") }
            return Response(status: 200, body: ["v": MobilePairingOffer.version, "name": macName])
        case ("POST", "/pair"):
            return await pair(request)
        default:
            return .error(404, "not_found")
        }
    }

    private func pair(_ request: HTTPRequest) async -> Response {
        guard let body = try? JSONDecoder().decode(PairBody.self, from: request.body), body.v == MobilePairingOffer.version else {
            return .error(400, "bad_request")
        }
        let proven = MobilePairingOffer.isProof(body.proof, of: MobilePairingOffer.pairMessage(key: body.key, name: body.name), code: code)
        let refusal: Response? = state.withLock { state in
            if state.spent || state.failedProofs >= Self.maximumFailedProofs { return .error(410, "used") }
            guard proven else {
                state.failedProofs += 1
                return .error(401, "bad_proof")
            }
            if state.deciding { return .error(409, "busy") }
            return nil
        }
        if let refusal { return refusal }
        guard let key = SSHPublicKeyLine(body.key), SSHPublicKeyLine.phoneKeyTypes.contains(key.type) else {
            return .error(400, "bad_key")
        }
        let starts = state.withLock { state in
            guard !state.deciding, !state.spent else { return false }
            state.deciding = true
            return true
        }
        guard starts else { return .error(409, "busy") }
        let answer = await decide(Request(key: key, name: AuthorizedPhoneKeys.cleanName(body.name)))
        state.withLock { state in
            state.deciding = false
            state.spent = true
        }
        return switch answer {
        case .added: Response(status: 200, body: ["v": MobilePairingOffer.version, "name": macName, "user": user])
        case .declined: .error(403, "declined")
        case .failed(let message): .error(500, "not_added", message: message)
        }
    }
}

/// An HTTP/1.1 request as the pairing listener reads it: its method, path,
/// query and body (`Content-Length` bytes).
struct HTTPRequest: Equatable, Sendable {
    struct Malformed: Error {}

    var method: String
    var path: String
    var query: [String: String]
    var body: Data

    /// The request `data` holds, nil while it is incomplete; throws when it
    /// is malformed or larger than `limit`.
    init?(parsing data: Data, limit: Int) throws {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > limit { throw Malformed() }
            return nil
        }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1."),
              let target = URLComponents(string: "http://pairing" + parts[1])
        else { throw Malformed() }
        var length = 0
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].lowercased() == "content-length" {
                guard let value = Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)), value >= 0 else {
                    throw Malformed()
                }
                length = value
            }
        }
        let start = end.upperBound
        guard length <= limit, start - data.startIndex + length <= limit else { throw Malformed() }
        guard data.endIndex - start >= length else { return nil }
        method = String(parts[0])
        path = target.path
        query = Dictionary((target.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { first, _ in first }
        body = data.subdata(in: start..<(start + length))
    }
}
