import AppIntents
import WidgetKit
import GreenlightKit

// App Intents behind the widget buttons. They run in the widget extension's process,
// so they talk to the relay directly. Compiled into both the app and the widget.

enum GreenlightIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notPaired
    case needsReview

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notPaired: return "Open Greenlight and pair it with your relay first."
        case .needsReview: return "This one is high risk. Open Greenlight to review it."
        }
    }
}

enum IntentActions {
    /// Answers an ask, refusing approvals above `maxRisk` even if a button was somehow shown.
    static func answer(askId: String, option: String, maxRisk: Risk, source: String) async throws {
        let store = SharedStore()
        guard let client = store.client else { throw GreenlightIntentError.notPaired }
        if option == "allow" {
            let ask = try await client.ask(id: askId)
            guard ask.risk <= maxRisk else { throw GreenlightIntentError.needsReview }
        }
        _ = try await client.answer(askId: askId, option: option, device: source)
        await refreshWidgets(client: client, store: store)
    }

    static func setPaused(_ paused: Bool) async throws {
        let store = SharedStore()
        guard let client = store.client else { throw GreenlightIntentError.notPaired }
        try await client.setPaused(paused)
        await refreshWidgets(client: client, store: store)
    }

    static func refreshWidgets(client: RelayClient, store: SharedStore) async {
        if let snapshot = try? await client.snapshot() { store.save(snapshot) }
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// Low-risk answers: one tap, even from the Lock Screen.
struct AnswerAskIntent: AppIntent {
    static let title: LocalizedStringResource = "Answer a Claude Code question"
    static let isDiscoverable = false

    @Parameter(title: "Question ID") var askId: String
    @Parameter(title: "Option") var option: String

    init() {}
    init(askId: String, option: String) {
        self.askId = askId
        self.option = option
    }

    func perform() async throws -> some IntentResult {
        try await IntentActions.answer(askId: askId, option: option, maxRisk: .low, source: "iPhone widget")
        return .result()
    }
}

/// Medium-risk answers: iOS asks to unlock the phone before running this.
struct AnswerAskUnlockedIntent: AppIntent {
    static let title: LocalizedStringResource = "Answer a Claude Code question (unlocked)"
    static let isDiscoverable = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Question ID") var askId: String
    @Parameter(title: "Option") var option: String

    init() {}
    init(askId: String, option: String) {
        self.askId = askId
        self.option = option
    }

    func perform() async throws -> some IntentResult {
        try await IntentActions.answer(askId: askId, option: option, maxRisk: .medium, source: "iPhone widget")
        return .result()
    }
}

/// The kill switch. Pausing and resuming both need an unlocked phone.
struct SetPausedIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause or resume all Claude Code sessions"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Paused") var paused: Bool

    init() {}
    init(paused: Bool) {
        self.paused = paused
    }

    func perform() async throws -> some IntentResult {
        try await IntentActions.setPaused(paused)
        return .result()
    }
}
