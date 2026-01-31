import Darwin
import Foundation
import Network

struct DaemonHealth: Decodable {
    let status: String
    let pid: Int
    let version: String
    let protocolVersion: Int

    enum CodingKeys: String, CodingKey {
        case status, pid, version
        case protocolVersion = "protocol_version"
    }
}

struct DaemonErrorInfo: Decodable {
    let code: String
    let message: String
}

struct DaemonResponse<Payload: Decodable>: Decodable {
    let ok: Bool
    let id: String?
    let data: Payload?
    let error: DaemonErrorInfo?
}

struct DaemonRequest<Params: Encodable>: Encodable {
    let protocolVersion: Int
    let method: String
    let id: String?
    let params: Params?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case method, id, params
    }
}

enum DaemonClientError: Error {
    case disabled
    case invalidResponse
    case timeout
    case daemonUnavailable(String)
}

final class DaemonClient {
    static let shared = DaemonClient()

    private enum Constants {
        static let socketName = "daemon.sock"
        static let enabledEnv = "CAPACITOR_DAEMON_ENABLED"
        static let socketEnv = "CAPACITOR_DAEMON_SOCKET"
        static let protocolVersion = 1
        static let maxResponseBytes = 1_048_576
        static let timeoutSeconds: TimeInterval = 0.6
    }

    private let queue = DispatchQueue(label: "com.capacitor.daemon.client")

    private init() {}

    var isEnabled: Bool {
        guard let raw = getenv(Constants.enabledEnv) else {
            return false
        }
        let value = String(cString: raw)
        return ["1", "true", "TRUE", "yes", "YES"].contains(value)
    }

    func fetchHealth() async throws -> DaemonHealth {
        try await performRequest(method: "get_health", params: Optional<String>.none)
    }

    func fetchShellState() async throws -> ShellCwdState {
        let decoder = JSONDecoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateStr = try container.decode(String.self)
            if let date = formatter.date(from: dateStr) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(dateStr)")
        }

        return try await performRequest(
            method: "get_shell_state",
            params: Optional<String>.none,
            decoder: decoder
        )
    }

    private func performRequest<Params: Encodable, Payload: Decodable>(
        method: String,
        params: Params?,
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> Payload {
        guard isEnabled else {
            throw DaemonClientError.disabled
        }

        let request = DaemonRequest(
            protocolVersion: Constants.protocolVersion,
            method: method,
            id: UUID().uuidString,
            params: params
        )

        let encoder = JSONEncoder()
        let requestData = try encoder.encode(request) + Data([0x0A])
        let responseData = try await sendAndReceive(requestData)

        let response = try decoder.decode(DaemonResponse<Payload>.self, from: responseData)

        if response.ok, let data = response.data {
            return data
        }

        let message = response.error?.message ?? "Unknown daemon error"
        throw DaemonClientError.daemonUnavailable(message)
    }

    private func socketPath() throws -> String {
        if let override = getenv(Constants.socketEnv) {
            return String(cString: override)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".capacitor/\(Constants.socketName)")
    }

    private func sendAndReceive(_ requestData: Data) async throws -> Data {
        let path = try socketPath()
        let endpoint = NWEndpoint.unix(path: path)
        let connection = NWConnection(to: endpoint, using: .tcp)

        return try await withCheckedThrowingContinuation { continuation in
            var buffer = Data()
            var finished = false

            let timeout = DispatchWorkItem {
                if finished { return }
                finished = true
                connection.cancel()
                continuation.resume(throwing: DaemonClientError.timeout)
            }

            func finish(_ result: Result<Data, Error>) {
                if finished { return }
                finished = true
                timeout.cancel()
                connection.cancel()
                continuation.resume(with: result)
            }

            func receiveNext() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, isComplete, error in
                    if let error = error {
                        finish(.failure(error))
                        return
                    }

                    if let data = data {
                        buffer.append(data)
                        if buffer.count > Constants.maxResponseBytes {
                            finish(.failure(DaemonClientError.invalidResponse))
                            return
                        }

                        if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                            let slice = buffer.prefix(upTo: newlineIndex)
                            finish(.success(Data(slice)))
                            return
                        }
                    }

                    if isComplete {
                        finish(.success(buffer))
                        return
                    }

                    receiveNext()
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: requestData, completion: .contentProcessed { error in
                        if let error = error {
                            finish(.failure(error))
                        } else {
                            receiveNext()
                        }
                    })
                case .failed(let error):
                    finish(.failure(error))
                case .cancelled:
                    if !finished {
                        finish(.failure(DaemonClientError.invalidResponse))
                    }
                default:
                    break
                }
            }

            queue.asyncAfter(deadline: .now() + Constants.timeoutSeconds, execute: timeout)
            connection.start(queue: queue)
        }
    }
}
