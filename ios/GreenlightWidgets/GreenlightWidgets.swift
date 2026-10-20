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
            Themed { SessionsWidgetView(entry: entry) }
                .containerBackground(for: .widget) { WidgetBackground() }
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
            Themed { NeedsYouView(entry: entry) }
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

// MARK: - Design system
//
// One palette per look. In full colour (light and dark) the widget draws its own
// background and uses colour for status. In the accented modes (iOS 26 clear and
// tinted Liquid Glass, iOS 18 tinted) the system draws the glass and recolours the
// content, so status is carried by weight, opacity and the accent group instead.

struct Palette {
    var fg: Color
    var fg2: Color
    var fg3: Color
    var hairline: Color
    var panel: Color
    var amber: Color
    var blue: Color
    var green: Color
    var red: Color
    var gray: Color
    var primary: Color
    var onPrimary: Color
    var secondary: Color
    var onSecondary: Color
    var isGlass: Bool

    static func make(scheme: ColorScheme, mode: WidgetRenderingMode) -> Palette {
        if mode != .fullColor {
            let w = Color.white
            return Palette(fg: w, fg2: w.opacity(0.72), fg3: w.opacity(0.5), hairline: w.opacity(0.22),
                           panel: w.opacity(0.14), amber: w, blue: w, green: w, red: w, gray: w.opacity(0.6),
                           primary: w.opacity(0.92), onPrimary: .black.opacity(0.82),
                           secondary: w.opacity(0.2), onSecondary: w, isGlass: true)
        }
        if scheme == .dark {
            let w = Color(red: 0.96, green: 0.96, blue: 0.97)
            return Palette(fg: w, fg2: w.opacity(0.6), fg3: w.opacity(0.36), hairline: .white.opacity(0.09),
                           panel: .white.opacity(0.06),
                           amber: Color(red: 1.0, green: 0.70, blue: 0.25), blue: Color(red: 0.29, green: 0.64, blue: 1.0),
                           green: Color(red: 0.24, green: 0.86, blue: 0.45), red: Color(red: 1.0, green: 0.41, blue: 0.38),
                           gray: Color(white: 0.6),
                           primary: Color(red: 0.19, green: 0.82, blue: 0.35), onPrimary: Color(red: 0.02, green: 0.13, blue: 0.06),
                           secondary: .white.opacity(0.1), onSecondary: w, isGlass: false)
        }
        let ink = Color(red: 0.11, green: 0.11, blue: 0.12)
        return Palette(fg: ink, fg2: ink.opacity(0.58), fg3: ink.opacity(0.38), hairline: .black.opacity(0.08),
                       panel: Color(red: 0.46, green: 0.46, blue: 0.5).opacity(0.08),
                       amber: Color(red: 0.91, green: 0.51, blue: 0.05), blue: Color(red: 0.04, green: 0.48, blue: 1.0),
                       green: Color(red: 0.12, green: 0.65, blue: 0.29), red: Color(red: 0.90, green: 0.22, blue: 0.17),
                       gray: Color(white: 0.56),
                       primary: Color(red: 0.12, green: 0.65, blue: 0.29), onPrimary: .white,
                       secondary: Color(red: 0.46, green: 0.46, blue: 0.5).opacity(0.13), onSecondary: ink, isGlass: false)
    }

    func color(for state: SessionState) -> Color {
        switch state {
        case .needsYou: return amber
        case .failed: return red
        case .running: return blue
        case .paused: return gray
        case .done: return green
        }
    }

    func color(for risk: Risk) -> Color {
        switch risk {
        case .low: return green
        case .medium: return amber
        case .high: return red
        }
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.make(scheme: .light, mode: .fullColor)
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Works out the palette for the current look and hands it to the content.
struct Themed<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetRenderingMode) private var mode
    @ViewBuilder var content: Content

    var body: some View {
        content.environment(\.palette, Palette.make(scheme: scheme, mode: mode))
    }
}

/// Full-colour background. The system swaps it for glass in the clear and tinted looks.
struct WidgetBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if scheme == .dark {
            LinearGradient(colors: [Color(red: 0.14, green: 0.14, blue: 0.15), Color(red: 0.09, green: 0.09, blue: 0.11)],
                           startPoint: .top, endPoint: .bottom)
        } else {
            LinearGradient(colors: [.white, Color(red: 0.97, green: 0.97, blue: 0.98)], startPoint: .top, endPoint: .bottom)
        }
    }
}

enum Typography {
    static let count = Font.system(size: 56, weight: .semibold).monospacedDigit()
    static let countLarge = Font.system(size: 40, weight: .semibold).monospacedDigit()
    static let label = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13, weight: .semibold)
    static let detail = Font.system(size: 11.5, weight: .medium)
    static let meta = Font.system(size: 10.5, weight: .medium)
    static let brand = Font.system(size: 10.5, weight: .semibold)
    static let mono = Font.system(size: 12, weight: .regular, design: .monospaced)
}

// MARK: - Building blocks

/// The green signal dot plus the app name, in small caps.
struct BrandMark: View {
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(p.green)
                .frame(width: 8, height: 8)
                .background(Circle().fill(p.green.opacity(0.22)).frame(width: 13, height: 13))
                .widgetAccentable()
            Text("GREENLIGHT")
                .font(Typography.brand)
                .tracking(0.9)
                .foregroundStyle(p.fg2)
        }
    }
}

/// "greenlight · main" with the branch in a lighter weight.
struct SessionTitle: View {
    @Environment(\.palette) private var p
    let title: String
    var size: CGFloat = 13

    var body: some View {
        let parts = Rules.titleParts(title)
        (Text(parts.repo).foregroundStyle(p.fg).fontWeight(.semibold)
            + Text(parts.branch.map { " · \($0)" } ?? "").foregroundStyle(p.fg2).fontWeight(.medium))
            .font(.system(size: size))
            .lineLimit(1)
    }
}

struct RiskChip: View {
    @Environment(\.palette) private var p
    let risk: Risk

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(p.color(for: risk)).frame(width: 6, height: 6)
            Text(risk == .high ? "High risk" : risk.rawValue.capitalized)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(p.color(for: risk))
        }
        .fixedSize()
        .accessibilityLabel(risk.label)
    }
}

/// The command itself, never a paraphrase.
struct CommandText: View {
    @Environment(\.palette) private var p
    let text: String
    var lines = 1

    var body: some View {
        (Text("$ ").foregroundStyle(p.fg3) + Text(text).foregroundStyle(p.fg))
            .font(Typography.mono)
            .lineLimit(lines)
            .truncationMode(.middle)
    }
}

/// Capsule look shared by buttons and links. Prominent is the action, plain is the alternative.
struct Pill<Label: View>: View {
    @Environment(\.palette) private var p
    var prominent: Bool
    var height: CGFloat = 30
    @ViewBuilder var label: Label

    var body: some View {
        label
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(prominent ? p.onPrimary : p.onSecondary)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .padding(.horizontal, 12)
            .background(Capsule().fill(prominent ? p.primary : p.secondary))
            .widgetAccentable(prominent)
    }
}

struct PillButtonStyle: ButtonStyle {
    var prominent: Bool
    var height: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        Pill(prominent: prominent, height: height) { configuration.label }
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct StatusDot: View {
    @Environment(\.palette) private var p
    let state: SessionState

    var body: some View {
        Circle()
            .fill(p.color(for: state))
            .frame(width: 8, height: 8)
            .background {
                if state == .running || state == .needsYou {
                    Circle().fill(p.color(for: state).opacity(0.22)).frame(width: 14, height: 14)
                }
            }
            .frame(width: 14, height: 14)
            .accessibilityLabel(state.word)
    }
}

struct SessionRow: View {
    @Environment(\.palette) private var p
    let session: Session
    let now: Date
    var divider = true

    var body: some View {
        VStack(spacing: 0) {
            if divider { Rectangle().fill(p.hairline).frame(height: 0.5).padding(.bottom, 7) }
            HStack(alignment: .top, spacing: 8) {
                StatusDot(state: session.state).padding(.top, 2)
                VStack(alignment: .leading, spacing: 1) {
                    SessionTitle(title: session.title)
                    Text(session.line).font(Typography.detail).foregroundStyle(p.fg2).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(Rules.shortAgo(since: session.updatedAt, now: now))
                    .font(Typography.meta)
                    .foregroundStyle(p.fg3)
                    .padding(.top, 2)
            }
        }
    }
}

/// The question card: who's asking, what exactly, and the buttons its risk allows.
struct AskPanel: View {
    @Environment(\.palette) private var p
    let session: Session
    let ask: Ask
    var commandLines = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                SessionTitle(title: session.title, size: 12.5)
                Spacer(minLength: 4)
                RiskChip(risk: ask.risk)
            }
            Text(ask.question)
                .font(Typography.detail)
                .foregroundStyle(p.fg2)
                .padding(.top, 6)
            if !ask.detail.isEmpty {
                CommandText(text: ask.detail, lines: commandLines).padding(.top, 3)
            }
            Spacer(minLength: 8)
            AskButtons(ask: ask)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(p.panel))
        .invalidatableContent() // dims until the relay confirms a tap
    }
}

struct AskButtons: View {
    let ask: Ask

    var body: some View {
        let options = Rules.widgetOptions(for: ask)
        HStack(spacing: 6) {
            if options.isEmpty {
                // High risk: no approve button here. Open the app, read it, Face ID.
                Link(destination: DeepLink.ask(ask.id)) {
                    Pill(prominent: true) {
                        Label("Review in app", systemImage: "lock.fill").imageScale(.small)
                    }
                }
                if let deny = ask.options.first(where: { $0.id == "deny" }) {
                    answerButton(deny).frame(maxWidth: 96)
                }
            } else {
                ForEach(options) { answerButton($0) }
            }
        }
    }

    @ViewBuilder
    private func answerButton(_ option: AskOption) -> some View {
        let label = Group {
            if option.isApproval {
                Label(option.label, systemImage: "play.fill").imageScale(.small)
            } else {
                Text(option.label)
            }
        }
        if Rules.approvalMode(for: ask.risk) == .oneTap {
            Button(intent: AnswerAskIntent(askId: ask.id, option: option.id)) { label }
                .buttonStyle(PillButtonStyle(prominent: option.isApproval))
        } else {
            Button(intent: AnswerAskUnlockedIntent(askId: ask.id, option: option.id)) { label }
                .buttonStyle(PillButtonStyle(prominent: option.isApproval))
        }
    }
}

/// Big number with a label: the first thing you read.
struct CountBlock: View {
    @Environment(\.palette) private var p
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(count)")
                .font(Typography.count)
                .tracking(-1.5)
                .foregroundStyle(p.amber)
                .contentTransition(.numericText(value: Double(count)))
                .widgetAccentable()
            Text(count == 1 ? "needs you" : "need you")
                .font(Typography.label)
                .foregroundStyle(p.fg)
        }
    }
}

/// Shown when nothing needs you.
struct AllClearBlock: View {
    @Environment(\.palette) private var p
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 28, weight: .medium))
                .symbolRenderingMode(.palette)
                .foregroundStyle(p.isGlass ? Color.black.opacity(0.75) : p.onPrimary, p.green)
                .widgetAccentable()
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(p.fg)
        }
    }
}

// MARK: - Home Screen views

struct SessionsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.palette) private var p
    let entry: Entry

    private var snapshot: Snapshot { entry.snapshot }
    private var sessions: [Session] { Rules.sorted(snapshot.sessions) }
    private var pending: (session: Session, ask: Ask)? {
        sessions.lazy.compactMap { s in s.ask.map { (session: s, ask: $0) } }.first
    }
    private var updated: String {
        entry.status == .offline ? "Offline · \(Rules.staleness(since: entry.fetchedAt, now: entry.date))"
            : Rules.staleness(since: entry.fetchedAt, now: entry.date)
    }

    var body: some View {
        Group {
            if entry.status == .unpaired {
                unpaired
            } else {
                switch family {
                case .systemSmall: small
                case .systemLarge: large
                default: medium
                }
            }
        }
        .foregroundStyle(p.fg)
    }

    private var unpaired: some View {
        VStack(alignment: .leading, spacing: 8) {
            BrandMark()
            Spacer(minLength: 0)
            Text("Not paired").font(.system(size: 15, weight: .semibold))
            Text("Open Greenlight and pair it with your relay.")
                .font(Typography.detail)
                .foregroundStyle(p.fg2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(DeepLink.home)
    }

    // Small: the count, or a check when all is well.
    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrandMark()
            Spacer(minLength: 10)
            if snapshot.needsYou > 0 {
                CountBlock(count: snapshot.needsYou)
                Spacer(minLength: 6)
                if let pending {
                    Text(pending.session.title).font(Typography.detail).foregroundStyle(p.fg).lineLimit(1)
                    Text(pending.ask.question).font(Typography.detail).foregroundStyle(p.fg2).lineLimit(1)
                }
            } else {
                AllClearBlock(title: snapshot.sessions.isEmpty ? "No sessions" : (snapshot.paused ? "Paused" : "All clear"))
                Spacer(minLength: 6)
                Text(Rules.counts(snapshot)).font(Typography.detail).foregroundStyle(p.fg2).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(pending.map { DeepLink.ask($0.ask.id) } ?? DeepLink.home)
    }

    // Medium: count on the left; the question with its buttons, or the session list, on the right.
    private var medium: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                BrandMark()
                Spacer(minLength: 10)
                if snapshot.needsYou > 0 {
                    CountBlock(count: snapshot.needsYou)
                } else {
                    AllClearBlock(title: snapshot.paused ? "Paused" : (sessions.isEmpty ? "No sessions" : "All clear"))
                }
                Spacer(minLength: 6)
                Text(pending == nil ? updated : Rules.counts(snapshot))
                    .font(Typography.detail)
                    .foregroundStyle(p.fg2)
                    .lineLimit(1)
            }
            .frame(width: 96, alignment: .leading)

            if let pending {
                AskPanel(session: pending.session, ask: pending.ask)
            } else if sessions.isEmpty {
                Text("Start Claude Code with the Greenlight plugin to see sessions here.")
                    .font(Typography.detail)
                    .foregroundStyle(p.fg2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 7) {
                    ForEach(Array(sessions.prefix(3).enumerated()), id: \.element.id) { index, session in
                        SessionRow(session: session, now: entry.date, divider: index > 0)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // Large: headline, the question card, the other sessions, and the kill switch.
    private var large: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                BrandMark()
                Spacer()
                Text(updated).font(Typography.meta).foregroundStyle(p.fg3)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if snapshot.needsYou > 0 {
                    Text("\(snapshot.needsYou)")
                        .font(Typography.countLarge)
                        .tracking(-1)
                        .foregroundStyle(p.amber)
                        .contentTransition(.numericText(value: Double(snapshot.needsYou)))
                        .widgetAccentable()
                    Text(snapshot.needsYou == 1 ? "needs you" : "need you")
                        .font(.system(size: 15, weight: .semibold))
                } else {
                    Text(Rules.headline(snapshot)).font(.system(size: 22, weight: .semibold))
                }
            }
            .padding(.top, 10)

            if let pending {
                AskPanel(session: pending.session, ask: pending.ask, commandLines: 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }

            let others = sessions.filter { $0.id != pending?.session.id }.prefix(pending == nil ? 6 : 3)
            VStack(spacing: 7) {
                ForEach(Array(others.enumerated()), id: \.element.id) { index, session in
                    SessionRow(session: session, now: entry.date, divider: index > 0)
                }
            }
            .padding(.top, 14)

            if sessions.isEmpty {
                Text("Start Claude Code with the Greenlight plugin to see sessions here.")
                    .font(Typography.detail)
                    .foregroundStyle(p.fg2)
                    .padding(.top, 12)
            }

            Spacer(minLength: 8)

            HStack {
                Button(intent: SetPausedIntent(paused: !snapshot.paused)) {
                    Label(snapshot.paused ? "Resume all" : "Pause all",
                          systemImage: snapshot.paused ? "play.fill" : "pause.fill")
                        .imageScale(.small)
                }
                .buttonStyle(PillButtonStyle(prominent: snapshot.paused, height: 28))
                .frame(maxWidth: 130)
                Spacer()
                Text(Rules.counts(snapshot)).font(Typography.detail).foregroundStyle(p.fg2).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Lock Screen views

struct NeedsYouView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        let snapshot = entry.snapshot
        let count = snapshot.needsYou
        let total = max(snapshot.sessions.count, 1)
        switch family {
        case .accessoryCircular:
            Gauge(value: Double(count), in: 0...Double(total)) {
                Image(systemName: "hand.raised.fill")
            } currentValueLabel: {
                Text("\(count)").font(.system(size: 22, weight: .semibold)).widgetAccentable()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetURL(DeepLink.home)
            .accessibilityLabel("\(count) sessions need you")
        case .accessoryInline:
            Label(count > 0 ? "\(count) need you" : Rules.headline(snapshot), systemImage: "circle.fill")
        default:
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Circle().frame(width: 7, height: 7).widgetAccentable()
                    Text(Rules.headline(snapshot)).font(.headline).widgetAccentable()
                }
                if let top = Rules.sorted(snapshot.sessions).first {
                    // The question, never the command: the Lock Screen is visible to anyone.
                    Text(top.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(top.ask?.question ?? top.line).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(DeepLink.home)
        }
    }
}

#Preview("Medium", as: .systemMedium) {
    SessionsWidget()
} timeline: {
    Entry.placeholder
}

#Preview("Small", as: .systemSmall) {
    SessionsWidget()
} timeline: {
    Entry.placeholder
}

#Preview("Large", as: .systemLarge) {
    SessionsWidget()
} timeline: {
    Entry.placeholder
}

#Preview("Lock Screen", as: .accessoryRectangular) {
    NeedsYouWidget()
} timeline: {
    Entry.placeholder
}
