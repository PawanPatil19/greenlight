import SwiftUI
import GreenlightKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.config == nil {
            PairingView()
        } else {
            SessionsView()
        }
    }
}

/// First run: paste or open the link the relay printed.
struct PairingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var link = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Greenlight", systemImage: "checkmark.shield.fill")
                .font(.largeTitle.bold())
                .foregroundStyle(.green)
            Text("See your Claude Code sessions on your Home Screen and answer their permission prompts with one tap.")
            Text("Start the relay on your computer. It prints a link that starts with greenlight://pair. Open it on this iPhone, or paste it here.")
                .foregroundStyle(.secondary)
            TextField("greenlight://pair?relay=…&token=…", text: $link, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(.footnote, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            HStack {
                Button("Paste") { link = UIPasteboard.general.string ?? "" }
                    .buttonStyle(.bordered)
                Button("Pair") { model.pair(link: link) }
                    .buttonStyle(.borderedProminent)
                    .disabled(link.isEmpty)
            }
            if let message = model.message {
                Text(message).foregroundStyle(.red).font(.footnote)
            }
            Spacer()
            Text("Then long-press your Home Screen, tap Edit → Add Widget, and pick Greenlight.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

struct SessionsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text(Rules.headline(model.snapshot)).font(.title2.bold())
                        Spacer()
                        if let fetched = model.lastFetched {
                            Text(Rules.staleness(since: fetched)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: Binding(
                        get: { model.snapshot.paused },
                        set: { paused in Task { await model.setPaused(paused) } }
                    )) {
                        Label("Pause all sessions", systemImage: "pause.circle")
                    }
                    .tint(.orange)
                }

                Section("Sessions") {
                    if model.snapshot.sessions.isEmpty {
                        Text("No sessions yet. Start Claude Code with the Greenlight plugin.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Rules.sorted(model.snapshot.sessions)) { session in
                        SessionCell(session: session)
                    }
                }

                Section("Recent decisions") {
                    if model.audit.isEmpty {
                        Text("Nothing yet.").foregroundStyle(.secondary)
                    }
                    ForEach(model.audit) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(entry.outcome) · \(entry.sessionTitle)").font(.subheadline.weight(.semibold))
                            if !entry.detail.isEmpty {
                                Text(entry.detail).font(.system(.caption, design: .monospaced)).lineLimit(2)
                            }
                            Text("\(entry.at.formatted(date: .omitted, time: .shortened))\(entry.by.map { " · \($0)" } ?? "")")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Greenlight")
            .refreshable { await model.refresh() }
            .toolbar {
                Menu {
                    if let url = model.config?.baseURL { Text(url.absoluteString) }
                    Button("Unpair", role: .destructive) { model.unpair() }
                } label: {
                    Image(systemName: "gearshape")
                }
            }
            .task { await model.poll() }
            .sheet(item: $model.reviewing) { review in
                ReviewView(askId: review.id)
            }
            .overlay(alignment: .bottom) {
                if let message = model.message {
                    Text(message)
                        .font(.footnote)
                        .padding(10)
                        .background(.regularMaterial, in: Capsule())
                        .padding()
                        .onTapGesture { model.message = nil }
                }
            }
        }
    }
}

struct SessionCell: View {
    @EnvironmentObject private var model: AppModel
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                StateIcon(state: session.state)
                Text(session.title).font(.headline).lineLimit(1)
                if let ask = session.ask { RiskBadge(risk: ask.risk) }
            }
            Text(session.line).font(.subheadline).foregroundStyle(.secondary)
            if let ask = session.ask {
                Text(ask.detail)
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(3)
                Button("Review") { model.reviewing = AppModel.Review(id: ask.id) }
                    .buttonStyle(.borderedProminent)
            }
            if let host = session.host {
                Text(host).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Full details for one question. The only place high-risk actions can be approved.
struct ReviewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let askId: String

    var body: some View {
        NavigationStack {
            Group {
                if let found = model.ask(id: askId) {
                    let session = found.0
                    let ask = found.1
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text(ask.question).font(.title3.bold())
                                RiskBadge(risk: ask.risk)
                            }
                            Text("\(session.title)\(session.host.map { " · \($0)" } ?? "")")
                                .foregroundStyle(.secondary)
                            Text(ask.detail)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                            HStack(spacing: 4) {
                                Text("Falls back to the terminal")
                                Text(ask.expiresAt, style: .relative)
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            ForEach(ask.options) { option in
                                Button {
                                    Task { await model.answer(ask, with: option) }
                                } label: {
                                    Label(option.label, systemImage: icon(for: option))
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(option.tint)
                                .controlSize(.large)
                            }
                            if ask.risk > .low {
                                Text("Approving asks for Face ID or your passcode.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding()
                    }
                } else {
                    ContentUnavailableView(
                        "Already answered",
                        systemImage: "checkmark.circle",
                        description: Text("This question was answered in the terminal, timed out, or the session moved on.")
                    )
                }
            }
            .toolbar { Button("Close") { dismiss() } }
        }
    }

    private func icon(for option: AskOption) -> String {
        if option.isApproval { return "checkmark" }
        if option.isLocal { return "terminal" }
        return "xmark"
    }
}
