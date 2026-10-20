import SwiftUI
import WidgetKit
import GreenlightKit

@main
struct GreenlightWidgetsBundle: WidgetBundle {
    var body: some Widget {
        SessionsWidget()
        NeedsYouWidget()
    }
}

/// Home Screen widget: what needs you first, with Allow / Deny right on it.
struct SessionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.greenlight.sessions", provider: Provider()) { entry in
            SessionsWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Claude Code sessions")
        .description("See which sessions need you and answer their permission prompts.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

/// Lock Screen widget: just the count.
struct NeedsYouWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.greenlight.needs-you", provider: Provider()) { entry in
            NeedsYouView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Needs you")
        .description("How many Claude Code sessions are waiting on you.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Timeline

struct Entry: TimelineEntry {
    enum Status { case live, offline, unpaired }

    let date: Date
    let snapshot: Snapshot
    let fetchedAt: Date
    let status: Status

    static let placeholder = Entry(date: .now, snapshot: Samples.snapshot, fetchedAt: .now, status: .live)
    static let unpaired = Entry(date: .now, snapshot: .empty, fetchedAt: .now, status: .unpaired)
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
            return
        }
        Task { completion(await load()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        Task {
            let entry = await load()
            // iOS budgets widget reloads; pushes from the relay trigger reloads sooner.
            let next = Date().addingTimeInterval(Rules.refreshInterval(entry.snapshot))
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    private func load() async -> Entry {
        let store = SharedStore()
        guard let client = store.client else { return .unpaired }
        do {
            let snapshot = try await client.snapshot()
            store.save(snapshot)
            return Entry(date: .now, snapshot: snapshot, fetchedAt: .now, status: .live)
        } catch {
            // Show the last thing we knew, clearly marked as old.
            let cached = store.lastSnapshot
            return Entry(date: .now, snapshot: cached?.snapshot ?? .empty, fetchedAt: cached?.fetchedAt ?? .distantPast, status: .offline)
        }
    }
}

// MARK: - Home Screen views

struct SessionsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    private var sessions: [Session] { Rules.sorted(entry.snapshot.sessions) }
    private var firstAsk: (Session, Ask)? {
        sessions.lazy.compactMap { s in s.ask.map { (s, $0) } }.first
    }

    var body: some View {
        if entry.status == .unpaired {
            VStack(alignment: .leading, spacing: 4) {
                Label("Greenlight", systemImage: "checkmark.shield")
                    .font(.headline)
                Text("Open the app to pair with your relay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .widgetURL(DeepLink.home)
        } else {
            switch family {
            case .systemSmall: small
            case .systemLarge: large
            default: medium
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(Rules.headline(entry.snapshot))
                .font(.headline)
                .foregroundStyle(entry.snapshot.needsYou > 0 ? Color.orange : Color.primary)
            Spacer(minLength: 4)
            if entry.status == .offline {
                Image(systemName: "wifi.slash").font(.caption2).foregroundStyle(.secondary)
                    .accessibilityLabel("Relay unreachable")
            }
            if entry.fetchedAt != .distantPast {
                Text(entry.fetchedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(entry.snapshot.needsYou)")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(entry.snapshot.needsYou > 0 ? Color.orange : Color.green)
            Text(entry.snapshot.needsYou == 1 ? "needs you" : "need you")
                .font(.caption.weight(.semibold))
            Spacer(minLength: 0)
            if let top = sessions.first {
                Label(top.title, systemImage: top.state.symbol)
                    .font(.caption2)
                    .foregroundStyle(top.state.color)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(firstAsk.map { DeepLink.ask($0.1.id) } ?? DeepLink.home)
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let pending = firstAsk {
                AskBlock(session: pending.0, ask: pending.1, compact: true)
            } else {
                ForEach(sessions.prefix(3)) { SessionRow(session: $0) }
                if sessions.isEmpty { emptyText }
            }
            Spacer(minLength: 0)
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let pending = firstAsk {
                AskBlock(session: pending.0, ask: pending.1, compact: false)
                Divider()
            }
            ForEach(sessions.filter { $0.id != firstAsk?.0.id }.prefix(firstAsk == nil ? 6 : 4)) {
                SessionRow(session: $0)
            }
            if sessions.isEmpty { emptyText }
            Spacer(minLength: 0)
            Button(intent: SetPausedIntent(paused: !entry.snapshot.paused)) {
                Label(entry.snapshot.paused ? "Resume all" : "Pause all",
                      systemImage: entry.snapshot.paused ? "play.fill" : "pause.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(entry.snapshot.paused ? .green : .orange)
        }
    }

    private var emptyText: some View {
        Text("Start Claude Code with the Greenlight plugin to see sessions here.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct SessionRow: View {
    let session: Session

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            StateIcon(state: session.state).font(.subheadline)
            VStack(alignment: .leading, spacing: 0) {
                Text(session.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(session.line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// The question, the exact command, and the buttons the risk level allows.
struct AskBlock: View {
    let session: Session
    let ask: Ask
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                StateIcon(state: .needsYou).font(.caption)
                Text(session.title).font(.caption.weight(.semibold)).lineLimit(1)
                RiskBadge(risk: ask.risk)
            }
            Text(ask.detail.isEmpty ? ask.question : ask.detail)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(compact ? 1 : 3)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            buttons
        }
    }

    @ViewBuilder private var buttons: some View {
        let options = Rules.widgetOptions(for: ask)
        if options.isEmpty {
            // High risk: no approve button on the widget. Open the app, read it, Face ID.
            Link(destination: DeepLink.ask(ask.id)) {
                Label("Review in app", systemImage: "lock.shield")
                    .font(.caption.weight(.semibold))
            }
        } else {
            HStack(spacing: 6) {
                ForEach(options) { option in
                    if Rules.approvalMode(for: ask.risk) == .unlockRequired {
                        Button(intent: AnswerAskUnlockedIntent(askId: ask.id, option: option.id)) {
                            Text(option.label).font(.caption.weight(.semibold))
                        }
                        .tint(option.tint)
                    } else {
                        Button(intent: AnswerAskIntent(askId: ask.id, option: option.id)) {
                            Text(option.label).font(.caption.weight(.semibold))
                        }
                        .tint(option.tint)
                    }
                }
            }
            .buttonStyle(.bordered)
        }
    }
}

// MARK: - Lock Screen views

struct NeedsYouView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        let count = entry.snapshot.needsYou
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: count > 0 ? "hand.raised.fill" : "checkmark")
                        .font(.caption)
                    Text("\(count)").font(.title3.weight(.bold))
                }
            }
            .widgetURL(DeepLink.home)
            .accessibilityLabel("\(count) sessions need you")
        case .accessoryInline:
            Text(count > 0 ? "\(count) need you" : Rules.headline(entry.snapshot))
        default:
            VStack(alignment: .leading, spacing: 1) {
                Text(Rules.headline(entry.snapshot)).font(.headline)
                if let top = Rules.sorted(entry.snapshot.sessions).first {
                    Text(top.title).font(.caption).lineLimit(1)
                    Text(top.line).font(.caption2).lineLimit(1)
                }
            }
            .widgetURL(DeepLink.home)
        }
    }
}

#Preview(as: .systemMedium) {
    SessionsWidget()
} timeline: {
    Entry.placeholder
}

#Preview(as: .systemLarge) {
    SessionsWidget()
} timeline: {
    Entry.placeholder
}
