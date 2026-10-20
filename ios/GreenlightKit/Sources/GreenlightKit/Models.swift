import Foundation

// Mirrors docs/protocol.md and relay/src/protocol.ts.

public enum SessionState: String, Codable, Sendable, CaseIterable {
    case needsYou = "needs_you"
    case failed
    case running
    case paused
    case done

    /// Unknown future states decode as `.running` rather than failing the whole snapshot.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SessionState(rawValue: raw) ?? .running
    }

    /// Lower is more urgent: what needs the user comes first.
    public var urgency: Int {
        switch self {
        case .needsYou: return 0
        case .failed: return 1
        case .running: return 2
        case .paused: return 3
        case .done: return 4
        }
    }

    public var word: String {
        switch self {
        case .needsYou: return "Needs you"
        case .failed: return "Failed"
        case .running: return "Running"
        case .paused: return "Paused"
        case .done: return "Done"
        }
    }
}

public enum Risk: String, Codable, Sendable, Comparable {
    case low, medium, high

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Risk(rawValue: raw) ?? .high // unknown risk is treated as the safest case
    }

    private var rank: Int { self == .low ? 0 : self == .medium ? 1 : 2 }
    public static func < (a: Risk, b: Risk) -> Bool { a.rank < b.rank }
}

public struct AskOption: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    /// "primary", "destructive" or "neutral".
    public var style: String?

    public init(id: String, label: String, style: String? = nil) {
        self.id = id
        self.label = label
        self.style = style
    }

    /// The reserved option that hands the question back to the agent's own prompt.
    public var isLocal: Bool { id == "terminal" }
    public var isApproval: Bool { id == "allow" }
}

public struct Ask: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var sessionId: String
    public var question: String
    public var detail: String
    public var options: [AskOption]
    public var risk: Risk
    public var timeoutSec: Int
    public var status: String
    public var createdAt: Date
    public var expiresAt: Date
    public var answer: String?
    public var answeredAt: Date?
    public var answeredBy: String?
    public var closedReason: String?

    public var isPending: Bool { status == "pending" }
}

public struct Session: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var agent: String
    public var title: String
    public var state: SessionState
    public var step: String?
    public var summary: String?
    public var host: String?
    public var startedAt: Date
    public var updatedAt: Date
    public var ask: Ask?

    /// The one line shown under the title.
    public var line: String {
        if let ask { return ask.question }
        if state == .done, let summary { return summary }
        return step ?? state.word
    }
}

public struct Snapshot: Codable, Hashable, Sendable {
    public var sessions: [Session]
    public var needsYou: Int
    public var paused: Bool
    public var serverTime: Date

    public init(sessions: [Session], needsYou: Int, paused: Bool, serverTime: Date) {
        self.sessions = sessions
        self.needsYou = needsYou
        self.paused = paused
        self.serverTime = serverTime
    }

    public static let empty = Snapshot(sessions: [], needsYou: 0, paused: false, serverTime: .distantPast)
}

public struct AuditEntry: Codable, Hashable, Sendable, Identifiable {
    public var at: Date
    public var askId: String
    public var sessionId: String
    public var sessionTitle: String
    public var question: String
    public var detail: String
    public var risk: Risk
    public var outcome: String
    public var by: String?

    public var id: String { "\(at.timeIntervalSince1970)-\(askId)-\(outcome)" }
}

// MARK: - JSON

public enum GreenlightJSON {
    /// The relay sends `Date.toISOString()`: always UTC with milliseconds.
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let raw = try d.singleValueContainer().decode(String.self)
            if let date = parseDate(raw) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "bad date \(raw)"))
        }
        return decoder
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, e in
            var c = e.singleValueContainer()
            try c.encode(formatDate(date))
        }
        return encoder
    }

    static func parseDate(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }

    static func formatDate(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
