# Architecture — ClimCorse

## Overview

```
┌─────────────────────────────────────────────┐
│  Views                                      │
│  ContentView · DeviceDetailView             │
│  MenuBarView · SignInView · SettingsView    │
└───────────────────┬─────────────────────────┘
                    │ @EnvironmentObject
┌───────────────────▼─────────────────────────┐
│  ClimateViewModel                           │
│  polling · optimistic writes · debounce     │
└───────────────────┬─────────────────────────┘
                    │
┌───────────────────▼─────────────────────────┐
│  ComfortCloudClient                         │
│  devices · state (live→cached) · control    │
└──────┬──────────────────────┬───────────────┘
       │                      │
┌──────▼───────────┐  ┌───────▼────────────────┐
│ ComfortCloudAuth │  │ RequestSigner          │
│ OAuth2 + PKCE    │  │ x-cfc-api-key, headers │
└──────┬───────────┘  └────────────────────────┘
       │
┌──────▼───────────┐
│ Keychain         │
│ tokens           │
└──────────────────┘
```

## Source of truth for the protocol

Panasonic publishes no API. Every constant, header and endpoint comes from the
official Android app's behaviour, as implemented by the maintained open-source
client `aio-panasonic-comfort-cloud` (the one behind the Home Assistant
integration `sockless-coding/panasonic_cc`). These were read from source, not
recalled — the protocol changes and stale memory produces silent 401s.

## Authentication

OAuth 2.0 authorization-code flow with PKCE against Panasonic's Auth0 tenant at
`authglb.digital.panasonic.com`.

`ASWebAuthenticationSession` presents Panasonic's own login page. Panasonic
handles the password and two-factor challenge; the app only ever receives the
authorization code. The Python clients instead POST the credentials and scrape
Auth0's HTML response for hidden form fields — that breaks whenever Panasonic
redesigns the page, and it means holding the user's password.

The redirect URI is the Android app's custom scheme:
`panasonic-iot-cfc://authglb.digital.panasonic.com/android/com.panasonic.ACCsmart/callback`.
The app registers this scheme in `CFBundleURLTypes`. **If the callback proves
not to reach `ASWebAuthenticationSession`, the fallback is a `WKWebView` sheet
intercepting the redirect in `decidePolicyFor` — which also grants User-Agent
control.**

Sign-in is two-legged: after the token exchange, a POST to
`accsmart.panasonic.com/auth/v2/login` returns a `clientId` that must accompany
every subsequent call as `x-client-id`.

### Scope asymmetry

`/authorize` requests `openid offline_access comfortcloud.control a2w.control`,
but the token exchange sends only `openid`. Refresh reuses the *stored* scope.
This mirrors the official client; diverging gets the request refused.

## Request signing

Every call to the control API carries `x-cfc-api-key`:

```
SHA256("Comfort Cloud" + salt + timestamp_ms + "Bearer " + access_token)
→ hex[0..<9] + "cfc" + hex[9...]
```

The subtle part: the timestamp string is formatted in **local** time (and sent
as-is in `x-app-timestamp`), then re-parsed **as if it were UTC** to derive the
milliseconds. That offset is not a bug to fix — it is what the server expects.
Normalising it breaks every request outside UTC.

## Reading device state

`GET /deviceStatus/{guid}` reads the unit live. When a unit is unreachable the
call fails, and the client switches to `GET /deviceStatus/now/{guid}` — the
server-side cache — for ten polling cycles before retrying live. Wi-Fi modules
take a while to recover, and retrying live every cycle only piles up timeouts.

Device GUIDs contain `/` characters that the server expects replaced by `f`
before percent-encoding. Missing this silently breaks status reads on some units.

A temperature of `126` is a sentinel for an absent or offline probe, not a
reading; it is filtered out.

## Writing

`POST /deviceStatus/control` with `{"deviceGuid": …, "parameters": {…}}`.

Swing is the awkward case: "auto" is not a value of `airSwingLR`/`airSwingUD`
but a separate `fanAutoMode` field acting as a bitmask across *both* axes. So
setting one axis requires knowing the other's current state — the client takes
it from the last known device state rather than issuing an extra read.

## Distribution and updates

The app is distributed as a Developer ID–signed, notarised DMG and updates
itself through Sparkle 2.

**No sandbox.** Sparkle installs updates through XPC services. Inside a sandbox
that requires bundling `Downloader.xpc` / `Installer.xpc` and declaring
`temporary-exception.mach-lookup.global-name` entitlements; without them an
update downloads and then silently fails to install. Since distribution is
Developer ID rather than App Store, the sandbox buys nothing here. This matches
StarlinkInfos and ZendureMonitor.

**Signing key.** Updates are EdDSA-signed with a private key held in the login
keychain under the account `ClimCorse`; the public half is baked into the app as
`SUPublicEDKey`. The account name is not derivable from anything in the repo, so
it is recorded in `MEMORY.md` — `release.sh` depends on it. Regenerating the key
would make every installed copy reject all future updates.

**Version comparison.** Sparkle compares `<sparkle:version>` against the running
app's `CFBundleVersion` — a monotonically increasing integer — not against the
marketing version. Writing `0.1.0` there while the installed app reports
`CFBundleVersion` `1` would make the comparator read `[0,1,0] < [1]` and
conclude "already up to date". `release.sh` therefore reads the value straight
out of the built bundle.

**Ordering constraint.** The appcast and the GitHub release must land together.
The feed alone points Sparkle at a DMG that does not exist; the release alone is
invisible to the updater.

## UI behaviour

Cloud round-trips take seconds. Commands apply to the local model immediately
and reconcile on the next poll; a failed write restores the previous state and
surfaces the error. Temperature is debounced by 700 ms so dragging a slider
sends one request, not one per half-degree.
