import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct RelayConfig: Codable, Hashable, Sendable {
    public var baseURL: URL
    public var token: String

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }
}

public enum RelayError: Error, Equatable, LocalizedError {
    case unauthorized
    case notFound
    case http(Int, String?)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "The relay rejected the token. Pair again."
        case .notFound: return "Not found on the relay."
        case let .http(code, message): return "Relay error \(code)\(message.map { ": \($0)" } ?? "")"
        case .badResponse: return "The relay sent something unexpected."
        }
    }
}

/// What happened when the user tapped an option.
public enum AnswerOutcome: Equatable, Sendable {
    /// The relay took the answer (or already had this same answer).
    case accepted(Ask)
    /// Too late: answered in the terminal, timed out, or the session moved on.
    case closed
    /// Someone already chose a different option.
    case conflict
}

/// Minimal HTTP seam so the client can be tested without a network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        // Completion-handler API: available on every platform's Foundation.
        try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let http = response as? HTTPURLResponse {
                    continuation.resume(returning: (data ?? Data(), http.statusCode))
                } else {
                    continuation.resume(throwing: RelayError.badResponse)
                }
            }.resume()
        }
    }
}

public struct RelayClient: Sendable {
    public let config: RelayConfig
    private let transport: HTTPTransport
    private let timeout: TimeInterval

    public init(config: RelayConfig, transport: HTTPTransport = URLSessionTransport(), timeout: TimeInterval = 10) {
        self.config = config
        self.transport = transport
        self.timeout = timeout
    }

    // MARK: Phone API

    public func snapshot() async throws -> Snapshot {
        try await call("GET", "/v1/sessions")
    }

    public func ask(id: String) async throws -> Ask {
        try await call("GET", "/v1/asks/\(id)")
    }

    public func answer(askId: String, option: String, device: String) async throws -> AnswerOutcome {
        let (data, status) = try await raw("POST", "/v1/asks/\(askId)/answer", body: ["option": option, "device": device])
        switch status {
        case 200: return .accepted(try GreenlightJSON.decoder().decode(Ask.self, from: data))
        case 409: return .conflict
        case 410: return .closed
        default: throw error(status, data)
        }
    }

    @discardableResult
    public func setPaused(_ paused: Bool) async throws -> Bool {
        struct Control: Decodable { var paused: Bool }
        let control: Control = try await call("PUT", "/v1/control", body: ["paused": paused])
        return control.paused
    }

    public func audit(limit: Int = 50) async throws -> [AuditEntry] {
        struct Page: Decodable { var entries: [AuditEntry] }
        let page: Page = try await call("GET", "/v1/audit?limit=\(limit)")
        return page.entries
    }

    /// Registers this device for pushes. `tokenHex` is the APNs device token as lowercase hex.
    public func registerDevice(tokenHex: String, sandbox: Bool, name: String) async throws {
        let (data, status) = try await raw(
            "POST", "/v1/devices",
            body: ["token": tokenHex, "env": sandbox ? "sandbox" : "production", "name": name]
        )
        guard status == 201 else { throw error(status, data) }
    }

    // MARK: Plumbing

    func request(_ method: String, _ path: String, body: [String: Any]? = nil) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: config.baseURL) else { throw RelayError.badResponse }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        return request
    }

    private func raw(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> (Data, Int) {
        let (data, status) = try await transport.send(try request(method, path, body: body))
        if status == 401 { throw RelayError.unauthorized }
        return (data, status)
    }

    private func call<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> T {
        let (data, status) = try await raw(method, path, body: body)
        guard (200..<300).contains(status) else { throw error(status, data) }
        do {
            return try GreenlightJSON.decoder().decode(T.self, from: data)
        } catch {
            throw RelayError.badResponse
        }
    }

    private func error(_ status: Int, _ data: Data) -> RelayError {
        if status == 404 { return .notFound }
        struct Body: Decodable { var message: String? }
        return .http(status, try? JSONDecoder().decode(Body.self, from: data).message)
    }
}

extension Data {
    /// APNs device tokens are sent to the relay as lowercase hex.
    public var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
