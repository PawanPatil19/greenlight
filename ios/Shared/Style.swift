import SwiftUI
import GreenlightKit

// One status vocabulary everywhere: colour plus icon, never colour alone.

extension SessionState {
    var color: Color {
        switch self {
        case .needsYou: return .orange
        case .failed: return .red
        case .running: return .blue
        case .paused: return .gray
        case .done: return .green
        }
    }

    var symbol: String {
        switch self {
        case .needsYou: return "hand.raised.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .running: return "bolt.circle.fill"
        case .paused: return "pause.circle.fill"
        case .done: return "checkmark.circle.fill"
        }
    }
}

extension Risk {
    var color: Color {
        switch self {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        }
    }

    var label: String { rawValue.capitalized + " risk" }
}

extension AskOption {
    var tint: Color {
        switch style {
        case "primary": return .blue
        case "destructive": return .red
        default: return .gray
        }
    }
}

struct StateIcon: View {
    let state: SessionState

    var body: some View {
        Image(systemName: state.symbol)
            .foregroundStyle(state.color)
            .accessibilityLabel(state.word)
    }
}

struct RiskBadge: View {
    let risk: Risk

    var body: some View {
        Text(risk.rawValue.uppercased())
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(risk.color.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(risk.color)
            .accessibilityLabel(risk.label)
    }
}

enum DeepLink {
    static func ask(_ id: String) -> URL { URL(string: "greenlight://ask/\(id)")! }
    static let home = URL(string: "greenlight://home")!
}
