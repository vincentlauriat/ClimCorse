# ClimCorse

A macOS app to control Panasonic air conditioners from the menu bar or a full
window.

## Why cloud, not LAN

Panasonic's Wi-Fi modules and the CZ-TACG1 adapter expose **no local API**. Even
when the indoor units sit on your own network, the official app talks to
Panasonic's servers — and so does this one. ClimCorse speaks the Comfort Cloud
protocol, reconstructed from the official Android app (`com.panasonic.ACCsmart`).

## Features

| Feature | Status |
|---|---|
| Sign in with a Panasonic account (OAuth 2.0 + PKCE, 2FA handled by Panasonic) | ✅ |
| List every controllable indoor unit | ✅ |
| Power, mode, target temperature, fan speed, louvre swing | ✅ |
| Main window with unit sidebar and detail view | ✅ |
| Menu bar panel for quick changes | ✅ |
| Falls back to the server cache when a unit is unreachable | ✅ |
| Automatic updates via Sparkle | ✅ |
| Signed and notarised DMG | ✅ |
| Energy consumption history | ⏳ |

## Design notes

- **Optimistic UI.** Cloud writes take seconds to land. Changes show
  immediately, then reconcile on the next poll; a failed write rolls back.
- **Gentle polling.** Comfort Cloud rate-limits chatty clients. The default is
  120 s, matching the reference Home Assistant integration. Shorter intervals
  risk a temporary account lockout and gain nothing — the units only report
  every few minutes anyway.
- **Tokens live in the Keychain.** They grant physical control of heating and
  cooling.
- **Credentials never touch the app.** Sign-in happens on Panasonic's own page,
  presented by the system.

## Requirements

macOS 14 or later. A Panasonic Comfort Cloud account with at least one
registered air conditioner.

## Build

```sh
xcodegen generate
xcodebuild -scheme ClimCorse -configuration Debug build
```

## Caveats

The Comfort Cloud protocol is undocumented and can change without notice. If the
server starts rejecting requests because it considers the client too old, update
the Comfort Cloud app version number in Settings.

## Roadmap

- [x] Authentication, device listing, full control surface
- [x] Main window and menu bar panel
- [x] Sparkle auto-update and notarised DMG
- [ ] Validation against real hardware
- [ ] Energy consumption history

## License

MIT
