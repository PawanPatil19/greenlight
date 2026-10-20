# iOS app

The iPhone app, widgets, Live Activities and actionable notifications. Swift and SwiftUI, iOS 17+.

The Xcode project will be created on a Mac in a follow-up PR with this layout:

```
ios/
  Greenlight/            App target (SwiftUI): session list, approval detail, audit log
  GreenlightWidgets/     Widget extension: Home/Lock Screen widgets, Live Activity UI
  GreenlightKit/         Shared Swift package: protocol models, relay client
  GreenlightTests/
```

`GreenlightKit` mirrors the types in [`docs/protocol.md`](../docs/protocol.md) and [`relay/src/protocol.ts`](../relay/src/protocol.ts).
