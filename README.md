# OpenCode Mobile

> **This is not built by the OpenCode team and is not affiliated with them in
> any way.** It is an independent third-party client for a server someone runs
> themselves. "OpenCode" is used here only to name the software this app talks
> to, the same way any other client would. Please report anything that looks
> like an official release to the maintainer of this repository, not to the
> OpenCode project.

Android client for a running [OpenCode](https://opencode.ai) server: browse
projects, watch and drive sessions live, answer permission requests and
interactive questions from your phone — or run the server on the phone itself
and publish it to the internet.

## Why it exists

OpenCode ships a TUI and a web UI. Neither is good on a phone: the web UI needs
a reachable URL, the TUI needs a terminal. This app connects to the same
server over the documented HTTP API and presents the parts that matter on a
small screen — a running session, a pending approval, a token bill. And it
goes one step further: it can host a real OpenCode server on the device and
publish it, so the phone is the server rather than the thing being served.

## What it does

- **Connect.** Saved servers, password or QR pairing, opencode.ai account.
  Every launch starts disconnected; a server is always picked explicitly.
- **Browse.** Projects, sessions with live status, usage and spending.
- **Chat.** Streaming text and reasoning, tool cards, composer, stop, model
  and agent pickers. Retries and failures say so instead of spinning forever.
- **Approve.** Permission inbox with reply sheet, and interactive forms with
  an answer sheet — the agent stalls until someone answers, so both surface
  the same way.
- **Host.** Run OpenCode on the phone (musl build + bundled loader), with its
  own address, password, workspace and logs.
- **Publish.** Put the phone-hosted server on the internet through a tunnel:
  the app mints the key, gets it certified and finishes visitors' TLS on the
  device. The private key never leaves the phone.
- **Lock.** Optional biometric app lock, with the device PIN as fallback.

## Requirements

- Flutter 3.47+ and Dart 3.13+ (`flutter doctor` should be clean)
- Android SDK with platform 36, JDK 17
- An OpenCode server, v2 (the API this client targets was introduced in v2)

## Getting the app onto the phone

The server usually listens on `127.0.0.1` only, which a phone cannot reach.
Three supported routes:

### Over USB (no network configuration)

```sh
adb reverse tcp:4096 tcp:4096     # phone's localhost:4096 becomes your machine's
flutter run -d <device-id>
```

In the app enter `127.0.0.1:4096`.

### From anywhere

Publish the phone-hosted server from inside the app (see below), or pair
against a server that is already reachable:

```sh
opencode pair --remote             # prints a remote, e2e-encrypted address
```

Pair in the app using that link. A pairing code is single use and expires in
five minutes; the session it returns lasts 30 days.

### On the same LAN

```sh
opencode serve --hostname 0.0.0.0 --port 4096
```

Then use the machine's LAN address in the app.

## Connecting

Two authentication modes, because there are two things worth authenticating
with:

| Mode | When | Credential |
| --- | --- | --- |
| Password | you control the server | the password printed by `opencode serve` |
| Pairing link | the official flow, including the web UI | a session cookie, 30 day lifetime |

Both are stored in the Android Keystore-backed secure storage. Nothing
sensitive is written to `SharedPreferences` or logs.

The tunnel has its own files, and they are not in that storage: the private
key, the certificate and the token live as files in the app-private directory
(`opentunnel/` under app support). The sandbox keeps other apps out, but root
reads them like anything else — see [docs/protocol.md](docs/protocol.md) for
why that is accepted rather than hidden. The app never connects on
its own: no auto-restore, no default server.

## Running the server on the phone

Servers → This phone. The runtime (~200 MB: the musl OpenCode build plus its
libraries) downloads once, verifies against bundled digests, and starts. The
address is stable across restarts; the password is regenerated every start.
"Open it in the app" connects with one tap.

The phone is a hostile place for a server binary (no `/tmp`, no
`/etc/resolv.conf`, no executing downloads), and all of that is handled —
see [docs/ANDROID_RUNTIME.md](docs/ANDROID_RUNTIME.md).

## Publishing it to the internet

Servers → This phone → Connect another device → Internet. The app claims a
hostname, mints a key, gets a certificate issued for it, and attaches a
bridge; visitors' TLS is terminated on the device against that certificate.
Stopping answers but keeps the hostname; forgetting deletes the tunnel for
good. The wire protocol is documented in [docs/protocol.md](docs/protocol.md).

## Development

```sh
flutter pub get
flutter test                      # unit tests over recorded server fixtures
flutter analyze
flutter run -d <device-id>        # hot reload during development
```

Per-machine setup, device workflow and the gotchas this repo learned are in
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

### Tests

`test/` folds real captured event streams from `test/fixtures/events/*.ndjson`.
Those recordings are the reason the reducer is trustworthy: they are actual
server output, not hand-written shapes, so a change in the wire format shows up
as a failing test instead of a blank screen. Everything network-shaped (tunnel
bridge, proxy, pairing) is tested against fakes, never against a live service.

## Architecture

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — layers, state, event system,
  security, and what is deliberately not built yet.
- [docs/API.md](docs/API.md) — the API details this client depends on,
  including the parts the published OpenAPI document does not cover.
- [docs/ANDROID_RUNTIME.md](docs/ANDROID_RUNTIME.md) — running OpenCode on
  the device: loader, DNS, proxy, registry.
- [docs/protocol.md](docs/protocol.md) — the tunnel wire protocol.

## Status

Connect, browse, chat with streaming, permissions, forms, app lock, hosting
and publishing are implemented and covered. Deliberately not built yet: a diff
viewer, theming/accessibility polish, a release build, and a PTY terminal.
