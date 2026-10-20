# iOS app and widget

The widget is the product: it shows how many Claude Code sessions need you and has the answer buttons right on it. The app stays small: pairing, the review screen for high-risk approvals, settings and the decision history.

```
ios/
  project.yml           XcodeGen spec (the .xcodeproj is generated, not committed)
  GreenlightKit/        Swift package: protocol models, relay client, widget rules (tested in CI on Linux)
  Shared/               App Intents and styling, compiled into both the app and the widget
  Greenlight/           Host app: pairing, review screen with Face ID, notifications, push registration
  GreenlightWidgets/    Home Screen widget (small, medium, large) and Lock Screen widget
```

## What each surface does

| Surface | Shows | Buttons |
|---|---|---|
| Medium / large widget | "N need you", the waiting session with its exact command, other sessions, "updated … ago" | Low risk: one tap. Medium risk: iOS asks to unlock first. High risk: **Review in app** only. Large widget also has **Pause all** |
| Small widget | The count and the top session | Tap opens the question in the app |
| Lock Screen widget | The count | Tap opens the app |
| Notification | Session title and the short question (never the command) | Allow / Deny; high risk gets Review / Deny |
| App review screen | Full command, host, time left before the terminal takes over | Every option; approvals above low risk need Face ID or passcode |

## Looks

The widget follows the Home Screen style the user picks ([mockups](../docs/img/widget-mockup.png), source in [`docs/design/widget-mockup.html`](../docs/design/widget-mockup.html)):

- **Light and dark** (full colour): the widget draws its own soft gradient background and uses colour for status: amber needs you, blue running, red failed, green done.
- **Clear and tinted** (iOS 26 Liquid Glass, and tinted on iOS 18): the system draws the glass and recolours everything. The widget switches to a white palette and marks the count, the signal dot and the main button with `widgetAccentable()`, so status still reads through weight and opacity instead of colour.

The palette lives in one place (`Palette` in `GreenlightWidgets/GreenlightWidgets.swift`), picked from `colorScheme` and `widgetRenderingMode`.

## Run it on your iPhone

You need a Mac with Xcode 16+, an Apple ID, and the relay running on a computer your phone can reach (same Wi-Fi is fine).

1. Install XcodeGen and generate the project:
   ```sh
   brew install xcodegen
   cd ios && xcodegen
   open Greenlight.xcodeproj
   ```
2. Make the IDs yours. In `project.yml` change `bundleIdPrefix`, the two `PRODUCT_BUNDLE_IDENTIFIER`s and the App Group `group.dev.greenlight.app`, and set `DEVELOPMENT_TEAM` to your team id. Change `SharedStore.appGroup` in `GreenlightKit/Sources/GreenlightKit/SharedStore.swift` to the same App Group. Run `xcodegen` again.
   - A free Apple ID can run the app and widget, but can't use push notifications. Delete the `aps-environment` line in `project.yml` in that case. The widget still refreshes on its own schedule and right after every tap.
3. Plug in your iPhone, choose it as the run destination, and press Run. Turn on Developer Mode on the phone if iOS asks.
4. Start the relay on your computer (`cd relay && npm run dev`). It prints a `greenlight://pair?...` link. Send it to your phone (AirDrop or Notes), tap it, and Greenlight pairs. You can also paste it into the app.
5. Long-press the Home Screen → Edit → Add Widget → Greenlight. Add the medium one.
6. Start Claude Code with the plugin on the computer (`GREENLIGHT_RELAY_URL=http://localhost:8787 claude --plugin-dir ./plugin`) and ask it to do something that needs permission.

### Push notifications (optional, paid developer account)

Pushes make the widget update within seconds and give you Allow / Deny on the notification.

1. In the Apple developer portal, create an APNs key (Keys → +, tick Apple Push Notifications service). Download the `.p8` file and note the key id and your team id.
2. Start the relay with:
   ```sh
   APNS_KEY_ID=XXXXXXXXXX APNS_TEAM_ID=YYYYYYYYYY APNS_KEY_PATH=~/AuthKey_XXXXXXXXXX.p8 \
   APNS_TOPIC=<your app bundle id> npm run dev
   ```
3. Open the app once after pairing and allow notifications. Debug builds register as `sandbox`, release builds as `production`.

### Reaching the relay away from home

iOS only allows plain `http` to local network addresses. To use the widget away from your Wi-Fi, put the relay behind https: for example Tailscale (100.x addresses work over http too), or a tunnel such as `cloudflared tunnel --url http://localhost:8787`, then set `GREENLIGHT_PUBLIC_URL` so the pairing link uses that address.

## Checks

```sh
swift test --package-path ios/GreenlightKit   # what CI runs (Linux or macOS)
```

CI also generates the Xcode project and builds the app and widget for the simulator on macOS, unsigned, whenever `ios/` changes.

## Known gaps

- The token is kept in the App Group's user defaults, not the Keychain.
- No Live Activities, QR pairing or Apple Watch yet (see `docs/implementation-plan.md`).
