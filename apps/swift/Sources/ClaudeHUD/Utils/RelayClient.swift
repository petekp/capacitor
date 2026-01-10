import Foundation

struct RelayConfig: Codable {
    let relayUrl: String
    let deviceId: String
    let secretKey: String
}

struct RelayProjectState: Codable {
    let state: String
    let workingOn: String?
    let nextStep: String?
    let devServerPort: Int?
    let contextPercent: Double?
    let lastUpdated: String
}

struct RelayHudState: Codable {
    let projects: [String: RelayProjectState]
    let activeProject: String?
    let updatedAt: String
}

struct EncryptedMessage: Codable {
    let nonce: String
    let ciphertext: String
}

enum WebSocketMessageType: String, Codable {
    case stateUpdate = "state_update"
    case hello
    case ping
    case pong
}

struct WebSocketMessage: Codable {
    let type: WebSocketMessageType
    let state: EncryptedMessage?
    let deviceId: String?
}

@MainActor
class RelayClient: NSObject, ObservableObject {
    @Published var isConnected = false
    @Published var lastState: RelayHudState?
    @Published var connectionError: String?

    private var webSocket: URLSessionWebSocketTask?
    private var config: RelayConfig?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var isReconnecting = false

    override init() {
        super.init()
        loadConfig()
    }

    private func loadConfig() {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("hud-relay.json")

        guard FileManager.default.fileExists(atPath: configPath.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: configPath)
            config = try JSONDecoder().decode(RelayConfig.self, from: data)
        } catch {
            connectionError = "Failed to load relay config: \(error.localizedDescription)"
        }
    }

    var isConfigured: Bool {
        config != nil
    }

    func connect() {
        guard let config = config else {
            connectionError = "Relay not configured. Create ~/.claude/hud-relay.json"
            return
        }

        let wsUrl = config.relayUrl
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")

        guard let url = URL(string: "\(wsUrl)/api/v1/ws/\(config.deviceId)") else {
            connectionError = "Invalid relay URL"
            return
        }

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        webSocket = session.webSocketTask(with: url)
        webSocket?.resume()

        receiveMessage()
        startPingTimer()
    }

    func disconnect() {
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        isConnected = false
    }

    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                _Concurrency.Task { @MainActor in
                    self.handleMessage(message)
                    self.receiveMessage()
                }

            case .failure(let error):
                _Concurrency.Task { @MainActor in
                    self.handleDisconnection(error: error)
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            parseMessage(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                parseMessage(text)
            }
        @unknown default:
            break
        }
    }

    private func parseMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }

        do {
            let wsMessage = try JSONDecoder().decode(WebSocketMessage.self, from: data)

            switch wsMessage.type {
            case .stateUpdate:
                if let encrypted = wsMessage.state {
                    decryptAndApplyState(encrypted)
                }
            case .hello:
                isConnected = true
                reconnectAttempts = 0
                connectionError = nil
            case .pong:
                break
            case .ping:
                sendPong()
            }
        } catch {
            connectionError = "Failed to parse message: \(error.localizedDescription)"
        }
    }

    private func decryptAndApplyState(_ encrypted: EncryptedMessage) {
        guard let ciphertextData = Data(base64Encoded: encrypted.ciphertext),
              let jsonString = String(data: ciphertextData, encoding: .utf8),
              let jsonData = jsonString.data(using: .utf8) else {
            return
        }

        do {
            let state = try JSONDecoder().decode(RelayHudState.self, from: jsonData)
            lastState = state
        } catch {
            connectionError = "Failed to decode state: \(error.localizedDescription)"
        }
    }

    private func sendPong() {
        let pong = WebSocketMessage(type: .pong, state: nil, deviceId: nil)
        guard let data = try? JSONEncoder().encode(pong),
              let text = String(data: data, encoding: .utf8) else { return }

        webSocket?.send(.string(text)) { _ in }
    }

    private func startPingTimer() {
        _Concurrency.Task {
            while webSocket != nil {
                try? await _Concurrency.Task.sleep(nanoseconds: 30_000_000_000)
                guard webSocket != nil else { break }

                let ping = WebSocketMessage(type: .ping, state: nil, deviceId: nil)
                if let data = try? JSONEncoder().encode(ping),
                   let text = String(data: data, encoding: .utf8) {
                    webSocket?.send(.string(text)) { _ in }
                }
            }
        }
    }

    private func handleDisconnection(error: Error) {
        isConnected = false
        connectionError = error.localizedDescription

        guard !isReconnecting, reconnectAttempts < maxReconnectAttempts else { return }

        isReconnecting = true
        reconnectAttempts += 1

        let delay = min(pow(2.0, Double(reconnectAttempts)), 30.0)

        _Concurrency.Task {
            try? await _Concurrency.Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self.isReconnecting = false
            self.connect()
        }
    }
}

extension RelayClient: URLSessionWebSocketDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        _Concurrency.Task { @MainActor in
            self.isConnected = true
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        _Concurrency.Task { @MainActor in
            self.isConnected = false
            if closeCode != .normalClosure {
                self.handleDisconnection(error: NSError(
                    domain: "RelayClient",
                    code: Int(closeCode.rawValue),
                    userInfo: [NSLocalizedDescriptionKey: "WebSocket closed with code \(closeCode.rawValue)"]
                ))
            }
        }
    }
}
