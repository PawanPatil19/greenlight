import Foundation

/// Widget behaviour shared by every surface, so the app, widget and tests agree.
public enum Rules {
    public enum ApprovalMode: Equatable, Sendable {
        /// Buttons work right from the widget.
        case oneTap
        /// Buttons work from the widget, but iOS asks to unlock first.
        case unlockRequired
        /// No approve button on the widget: open the app, read the details, Face ID.
        case openApp
    }

    public static func approvalMode(for risk: Risk) -> ApprovalMode {
        switch risk {
        case .low: return .oneTap
        case .medium: return .unlockRequired
        case .high: return .openApp
        }
    }

    /// Approving needs Face ID / passcode inside the app for anything above low risk.
    public static func needsDeviceAuth(risk: Risk, option: AskOption) -> Bool {
        option.isApproval && risk > .low
    }

    public static func headline(_ snapshot: Snapshot) -> String {
        if snapshot.needsYou > 0 { return "\(snapshot.needsYou) need\(snapshot.needsYou == 1 ? "s" : "") you" }
        if snapshot.paused { return "All paused" }
        if snapshot.sessions.contains(where: { $0.state == .running }) { return "All running" }
        return snapshot.sessions.isEmpty ? "No sessions" : "Nothing needs you"
    }

    /// Most urgent first, then newest.
    public static func sorted(_ sessions: [Session]) -> [Session] {
        sessions.sorted {
            $0.state.urgency != $1.state.urgency ? $0.state.urgency < $1.state.urgency : $0.updatedAt > $1.updatedAt
        }
    }

    /// "Updated just now" / "Updated 4 min ago": a frozen widget must look frozen.
    public static func staleness(since: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        if seconds < 60 { return "Updated just now" }
        if seconds < 3600 { return "Updated \(seconds / 60) min ago" }
        return "Updated \(seconds / 3600) h ago"
    }

    /// Compact age for list rows: "now", "2m", "1h", "3d".
    public static func shortAgo(since: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }

    /// "2 running · 1 failed · 1 done", skipping states with no sessions.
    public static func counts(_ snapshot: Snapshot, excludingNeedsYou: Bool = true) -> String {
        let order: [SessionState] = [.needsYou, .running, .paused, .failed, .done]
        let parts = order.compactMap { state -> String? in
            if excludingNeedsYou && state == .needsYou { return nil }
            let n = snapshot.sessions.filter { $0.state == state }.count
            return n == 0 ? nil : "\(n) \(state.word.lowercased())"
        }
        return parts.isEmpty ? "No sessions" : parts.joined(separator: " · ")
    }

    /// Splits "repo · branch" for two-weight titles.
    public static func titleParts(_ title: String) -> (repo: String, branch: String?) {
        guard let range = title.range(of: " · ") else { return (title, nil) }
        return (String(title[..<range.lowerBound]), String(title[range.upperBound...]))
    }

    /// How soon the widget should ask iOS for a fresh timeline. Pushes refresh it sooner.
    public static func refreshInterval(_ snapshot: Snapshot) -> TimeInterval {
        if snapshot.needsYou > 0 { return 2 * 60 }
        if snapshot.sessions.contains(where: { $0.state == .running }) { return 5 * 60 }
        return 15 * 60
    }

    /// The options a widget shows for an ask: never the hand-back option, never approvals for high risk.
    public static func widgetOptions(for ask: Ask) -> [AskOption] {
        let options = ask.options.filter { !$0.isLocal }
        return approvalMode(for: ask.risk) == .openApp ? [] : options
    }
}
