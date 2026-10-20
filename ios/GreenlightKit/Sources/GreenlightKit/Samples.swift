import Foundation

/// Sample data for SwiftUI previews and the widget placeholder.
public enum Samples {
    public static let snapshotJSON = """
    {
      "sessions": [
        {
          "id": "s1", "agent": "claude-code", "title": "greenlight · main", "state": "needs_you",
          "step": "Run a shell command?", "host": "macbook",
          "startedAt": "2026-10-20T03:00:00.000Z", "updatedAt": "2026-10-20T03:10:00.000Z",
          "ask": {
            "id": "a1", "sessionId": "s1", "question": "Run a shell command?", "detail": "npm test -- auth",
            "options": [
              {"id": "allow", "label": "Run", "style": "primary"},
              {"id": "deny", "label": "Deny", "style": "destructive"},
              {"id": "terminal", "label": "Terminal", "style": "neutral"}
            ],
            "risk": "medium", "timeoutSec": 125, "status": "pending",
            "createdAt": "2026-10-20T03:10:00.000Z", "expiresAt": "2026-10-20T03:12:05.000Z"
          }
        },
        {
          "id": "s2", "agent": "claude-code", "title": "api · fix/rate-limit", "state": "running",
          "step": "Editing src/limits.ts",
          "startedAt": "2026-10-20T02:00:00.000Z", "updatedAt": "2026-10-20T03:09:30.000Z"
        },
        {
          "id": "s3", "agent": "claude-code", "title": "docs · main", "state": "done",
          "step": "Done", "summary": "Rewrote the setup guide.",
          "startedAt": "2026-10-20T01:00:00.000Z", "updatedAt": "2026-10-20T02:30:00.000Z"
        }
      ],
      "needsYou": 1,
      "paused": false,
      "serverTime": "2026-10-20T03:10:01.000Z"
    }
    """

    public static let snapshot: Snapshot = {
        // The JSON above is fixed and covered by tests, so this cannot fail.
        try! GreenlightJSON.decoder().decode(Snapshot.self, from: Data(snapshotJSON.utf8))
    }()
}
