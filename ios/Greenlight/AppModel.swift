import Foundation
import LocalAuthentication
import SwiftUI
import UIKit
import UserNotifications
import WidgetKit
import GreenlightKit

/// The app's state. The app is small on purpose: pairing, the review screen for
/// high-risk asks, settings. The widget is the product.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    struct Review: Identifiable, Hashable { let id: String } // an ask id

    @Published private(set) var config: RelayConfig?
    @Published private(set) var snapshot: Snapshot = .empty
    @Published private(set) var audit: [AuditEntry] = []
    @Published private(set) var lastFetched: Date?
    @Published var message: String?
    @Published var reviewing: Review?

    private let store = SharedStore()

    init() {
        config = store.config
        if let cached = store.lastSnapshot {
            snapshot = cached.snapshot
            lastFetched = cached.fetchedAt
        }
    }

    var client: RelayClient? { config.map { RelayClient(config: $0) } }

    // MARK: Pairing

    func pair(link: String) {
        do {
            let config = try Pairing.parse(link)
            store.config = config
            self.config = config
            message = nil
            Task {
                await refresh()
                await registerForPushes()
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func unpair() {
        store.config = nil
        config = nil
        snapshot = .empty
        audit = []
        WidgetCenter.shared.reloadAllTimelines()
    }

    func handle(url: URL) {
        guard url.scheme == "greenlight" else { return }
        switch url.host {
        case "pair": pair(link: url.absoluteString)
        case "ask":
            let id = url.lastPathComponent
            if !id.isEmpty, id != "/" { reviewing = Review(id: id) }
        default: break
        }
    }

    // MARK: Data

    /// Polls while the app is on screen. Pushes keep the widget fresh when it isn't.
    func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    func refresh() async {
        guard let client else { return }
        do {
            let next = try await client.snapshot()
            let changed = next.sessions != snapshot.sessions || next.paused != snapshot.paused
            snapshot = next
            lastFetched = Date()
            store.save(next)
            if changed {
                WidgetCenter.shared.reloadAllTimelines()
                audit = (try? await client.audit(limit: 30)) ?? audit
            }
            if message == RelayError.unauthorized.localizedDescription { message = nil }
        } catch RelayError.unauthorized {
            message = RelayError.unauthorized.localizedDescription
        } catch {
            // Keep showing the last snapshot; the "updated" time tells the user it's old.
        }
    }

    func ask(id: String) -> (Session, Ask)? {
        for session in snapshot.sessions {
            if let ask = session.ask, ask.id == id { return (session, ask) }
        }
        return nil
    }

    /// Answers an ask from inside the app. Approvals above low risk need Face ID or the passcode.
    func answer(_ ask: Ask, with option: AskOption) async {
        guard let client else { return }
        if Rules.needsDeviceAuth(risk: ask.risk, option: option) {
            let context = LAContext()
            let reason = "Approve: \(ask.detail.prefix(80))"
            guard (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true else {
                message = "Not approved: authentication was cancelled."
                return
            }
        }
        do {
            switch try await client.answer(askId: ask.id, option: option.id, device: "\(UIDevice.current.name) · app") {
            case .accepted: message = "\(option.label) sent."
            case .closed: message = "Too late: it was answered in the terminal or timed out."
            case .conflict: message = "It was already answered differently."
            }
        } catch {
            message = error.localizedDescription
        }
        reviewing = nil
        await refresh()
    }

    func setPaused(_ paused: Bool) async {
        guard let client else { return }
        do {
            try await client.setPaused(paused)
        } catch {
            message = error.localizedDescription
        }
        await refresh()
    }

    // MARK: Pushes

    func registerForPushes() async {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if !granted { message = "Notifications are off. The widget still works, but updates less often." }
        // Register even without alert permission: silent pushes still refresh the widget.
        UIApplication.shared.registerForRemoteNotifications()
    }

    func didRegister(deviceToken: Data) async {
        guard let client else { return }
        #if DEBUG
        let sandbox = true
        #else
        let sandbox = false
        #endif
        do {
            try await client.registerDevice(tokenHex: deviceToken.hexString, sandbox: sandbox, name: UIDevice.current.name)
        } catch {
            message = "Couldn't register for notifications: \(error.localizedDescription)"
        }
    }
}
