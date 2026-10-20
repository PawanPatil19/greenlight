import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import GreenlightKit

/// Fixtures are real responses captured from the relay (relay/ in this repo).
func fixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
    return try Data(contentsOf: url)
}

final class ModelTests: XCTestCase {
    func testDecodesRelaySessions() throws {
        let snapshot = try GreenlightJSON.decoder().decode(Snapshot.self, from: fixture("sessions.json"))
        XCTAssertGreaterThanOrEqual(snapshot.needsYou, 1)
        let first = try XCTUnwrap(snapshot.sessions.first)
        XCTAssertEqual(first.state, .needsYou)
        XCTAssertEqual(first.title, "greenlight · main")
        let ask = try XCTUnwrap(first.ask)
        XCTAssertEqual(ask.detail, "git push origin main")
        XCTAssertEqual(ask.risk, .high)
        XCTAssertEqual(ask.options.map(\.id), ["allow", "deny", "terminal"])
        XCTAssertTrue(ask.isPending)
        XCTAssertEqual(first.line, "Run a shell command?")
    }

    func testDecodesAskAndAudit() throws {
        let ask = try GreenlightJSON.decoder().decode(Ask.self, from: fixture("ask.json"))
        XCTAssertEqual(ask.timeoutSec, 300)
        XCTAssertGreaterThan(ask.expiresAt, ask.createdAt)

        struct Page: Decodable { var entries: [AuditEntry] }
        let page = try GreenlightJSON.decoder().decode(Page.self, from: fixture("audit.json"))
        XCTAssertFalse(page.entries.isEmpty)
        XCTAssertEqual(page.entries.first?.by, "Phone simulator")
    }

    func testSamplesDecode() {
        XCTAssertEqual(Samples.snapshot.sessions.count, 3)
        XCTAssertEqual(Samples.snapshot.sessions[2].line, "Rewrote the setup guide.")
    }

    func testUnknownValuesDecodeSafely() throws {
        let state = try JSONDecoder().decode([SessionState].self, from: Data(#"["sleeping"]"#.utf8))
        XCTAssertEqual(state, [.running])
        let risk = try JSONDecoder().decode([Risk].self, from: Data(#"["extreme"]"#.utf8))
        XCTAssertEqual(risk, [.high], "unknown risk must be treated as high")
    }

    func testSnapshotRoundTripsThroughSharedStore() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "greenlight-tests-\(UUID().uuidString)"))
        let store = SharedStore(defaults: defaults)
        XCTAssertNil(store.config)
        store.config = RelayConfig(baseURL: URL(string: "http://192.168.1.5:8787")!, token: "t")
        XCTAssertEqual(store.config?.token, "t")
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        store.save(Samples.snapshot, fetchedAt: at)
        XCTAssertEqual(store.lastSnapshot?.snapshot, Samples.snapshot)
        XCTAssertEqual(store.lastSnapshot?.fetchedAt, at)
        store.config = nil
        XCTAssertNil(store.lastSnapshot, "unpairing forgets the cached snapshot")
    }
}

final class PairingTests: XCTestCase {
    func testParsesTheRelayLink() throws {
        let config = try Pairing.parse("greenlight://pair?relay=http%3A%2F%2F192.168.1.20%3A8787&token=abc_123-x")
        XCTAssertEqual(config.baseURL.absoluteString, "http://192.168.1.20:8787")
        XCTAssertEqual(config.token, "abc_123-x")
    }

    func testRejectsBadLinks() {
        XCTAssertThrowsError(try Pairing.parse("https://example.com")) { XCTAssertEqual($0 as? Pairing.Failure, .notAPairingLink) }
        XCTAssertThrowsError(try Pairing.parse("greenlight://pair?token=x")) { XCTAssertEqual($0 as? Pairing.Failure, .missingRelay) }
        XCTAssertThrowsError(try Pairing.parse("greenlight://pair?relay=http%3A%2F%2Fexample.com&token=x")) {
            XCTAssertEqual($0 as? Pairing.Failure, .insecureRelay)
        }
        XCTAssertThrowsError(try Pairing.parse("greenlight://pair?relay=https%3A%2F%2Frelay.example.com")) {
            XCTAssertEqual($0 as? Pairing.Failure, .missingToken)
        }
    }

    func testLocalHosts() {
        for host in ["localhost", "mac.local", "10.0.0.2", "192.168.1.1", "172.20.1.1", "100.100.1.1", "127.0.0.1"] {
            XCTAssertTrue(Pairing.isLocal(host), host)
        }
        for host in ["8.8.8.8", "172.32.0.1", "example.com"] {
            XCTAssertFalse(Pairing.isLocal(host), host)
        }
    }
}

final class RulesTests: XCTestCase {
    func testRiskDecidesWhereYouCanApprove() throws {
        XCTAssertEqual(Rules.approvalMode(for: .low), .oneTap)
        XCTAssertEqual(Rules.approvalMode(for: .medium), .unlockRequired)
        XCTAssertEqual(Rules.approvalMode(for: .high), .openApp)

        var ask = try XCTUnwrap(Samples.snapshot.sessions[0].ask)
        XCTAssertEqual(Rules.widgetOptions(for: ask).map(\.id), ["allow", "deny"])
        ask.risk = .high
        XCTAssertEqual(Rules.widgetOptions(for: ask), [])

        let allow = AskOption(id: "allow", label: "Run")
        let deny = AskOption(id: "deny", label: "Deny")
        XCTAssertTrue(Rules.needsDeviceAuth(risk: .medium, option: allow))
        XCTAssertFalse(Rules.needsDeviceAuth(risk: .high, option: deny))
        XCTAssertFalse(Rules.needsDeviceAuth(risk: .low, option: allow))
    }

    func testHeadlineLeadsWithNeedsYou() {
        var s = Samples.snapshot
        XCTAssertEqual(Rules.headline(s), "1 needs you")
        s.needsYou = 2
        XCTAssertEqual(Rules.headline(s), "2 need you")
        s.needsYou = 0
        XCTAssertEqual(Rules.headline(s), "All running")
        s.paused = true
        XCTAssertEqual(Rules.headline(s), "All paused")
        XCTAssertEqual(Rules.headline(.empty), "No sessions")
    }

    func testSortingAndStaleness() {
        let shuffled = Samples.snapshot.sessions.reversed()
        XCTAssertEqual(Rules.sorted(Array(shuffled)).map(\.id), ["s1", "s2", "s3"])
        let now = Date()
        XCTAssertEqual(Rules.staleness(since: now.addingTimeInterval(-20), now: now), "Updated just now")
        XCTAssertEqual(Rules.staleness(since: now.addingTimeInterval(-240), now: now), "Updated 4 min ago")
        XCTAssertEqual(Rules.refreshInterval(Samples.snapshot), 120)
    }
}

/// Records requests and replays canned responses.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    var responses: [(Int, String)]
    var requests: [URLRequest] = []
    init(_ responses: [(Int, String)]) { self.responses = responses }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        let (status, body) = responses.removeFirst()
        return (Data(body.utf8), status)
    }
}

final class ClientTests: XCTestCase {
    let config = RelayConfig(baseURL: URL(string: "http://192.168.1.20:8787")!, token: "tok")

    func testAnswerSendsTokenAndMapsOutcomes() async throws {
        let ask = String(decoding: try fixture("ask.json"), as: UTF8.self)
        let mock = MockTransport([(200, ask), (410, #"{"error":"closed"}"#), (409, #"{"error":"conflict"}"#)])
        let client = RelayClient(config: config, transport: mock)

        let first = try await client.answer(askId: "a1", option: "allow", device: "iPhone")
        guard case let .accepted(answered) = first else { return XCTFail("expected accepted") }
        XCTAssertEqual(answered.detail, "git push origin main")
        let second = try await client.answer(askId: "a1", option: "allow", device: "iPhone")
        XCTAssertEqual(second, .closed)
        let third = try await client.answer(askId: "a1", option: "deny", device: "iPhone")
        XCTAssertEqual(third, .conflict)

        let request = try XCTUnwrap(mock.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://192.168.1.20:8787/v1/asks/a1/answer")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"device":"iPhone","option":"allow"}"#)
    }

    func testUnauthorizedIsItsOwnError() async {
        let client = RelayClient(config: config, transport: MockTransport([(401, #"{"error":"unauthorized"}"#)]))
        do {
            _ = try await client.snapshot()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? RelayError, .unauthorized)
        }
    }

    func testSnapshotPauseAndDevices() async throws {
        let sessions = String(decoding: try fixture("sessions.json"), as: UTF8.self)
        let mock = MockTransport([(200, sessions), (200, #"{"paused":true}"#), (201, #"{"env":"sandbox"}"#)])
        let client = RelayClient(config: config, transport: mock)
        let snapshot = try await client.snapshot()
        XCTAssertEqual(snapshot.sessions.first?.id, "fx")
        let paused = try await client.setPaused(true)
        XCTAssertTrue(paused)
        try await client.registerDevice(tokenHex: Data([0xab, 0x01]).hexString, sandbox: true, name: "iPhone")
        XCTAssertEqual(mock.requests[1].httpMethod, "PUT")
        XCTAssertEqual(String(decoding: mock.requests[2].httpBody ?? Data(), as: UTF8.self), #"{"env":"sandbox","name":"iPhone","token":"ab01"}"#)
    }
}
