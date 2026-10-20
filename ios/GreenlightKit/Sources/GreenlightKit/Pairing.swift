import Foundation

/// Parses the link the relay prints: `greenlight://pair?relay=<url>&token=<token>`.
public enum Pairing {
    public enum Failure: Error, Equatable, LocalizedError {
        case notAPairingLink
        case missingRelay
        case insecureRelay
        case missingToken

        public var errorDescription: String? {
            switch self {
            case .notAPairingLink: return "That isn't a Greenlight pairing link."
            case .missingRelay: return "The link has no relay address."
            case .insecureRelay: return "Use https, or http only on your local network."
            case .missingToken: return "The link has no token."
            }
        }
    }

    public static func parse(_ text: String) throws -> RelayConfig {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme == "greenlight", components.host == "pair"
        else { throw Failure.notAPairingLink }
        let items = components.queryItems ?? []
        guard let relay = items.first(where: { $0.name == "relay" })?.value,
              let url = URL(string: relay), let host = url.host, !host.isEmpty
        else { throw Failure.missingRelay }
        guard url.scheme == "https" || (url.scheme == "http" && isLocal(host)) else { throw Failure.insecureRelay }
        guard let token = items.first(where: { $0.name == "token" })?.value, !token.isEmpty else {
            throw Failure.missingToken
        }
        return RelayConfig(baseURL: url, token: token)
    }

    /// Hosts iOS lets an app reach over plain http with `NSAllowsLocalNetworking`.
    static func isLocal(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        case (100, 64...127): return true // Tailscale / CGNAT
        default: return false
        }
    }
}
