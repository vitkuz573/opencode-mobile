# OpenCode Mobile

> **This is not built by the OpenCode team and is not affiliated with them in
> any way.** It is an independent third-party client for a server someone runs
> themselves. "OpenCode" is used here only to name the software this app talks
> to, the same way any other client would. Please report anything that looks
> like an official release to the maintainer of this repository, not to the
> OpenCode project.

Android client for a running [OpenCode](https://opencode.ai) server: browse
projects, watch and drive sessions live, answer permission requests from your
phone.

## Why it exists

OpenCode ships a TUI and a web UI. Neither is good on a phone: the web UI needs
a reachable URL, the TUI needs a terminal. This app connects to the same
server over the documented HTTP API and presents the parts that matter on a
small screen — a running session, a pending approval, a token bill.

## Requirements

- Flutter 3.47+ and Dart 3.13+ (`flutter doctor` should be clean)
- Android SDK with platform 36
- An OpenCode server, v2 (the API this client targets was introduced in v2)

## Getting the app onto the phone

The server usually listens on `127.0.0.1` only, which a phone cannot reach. Two
supported routes:

### Over USB (no network configuration)

```sh
adb reverse tcp:4096 tcp:4096     # phone's localhost:4096 becomes your machine's
flutter run -d <device-id>
```

In the app enter `127.0.0.1:4096`.

### From anywhere

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

## Development

```sh
flutter pub get
flutter test                      # unit tests over recorded server fixtures
flutter analyze
flutter run -d <device-id>        # hot reload during development
```

### Running the data layer against a live server

The API client and the SSE parser do not depend on Flutter, so they can be
exercised headlessly:

```sh
OPENCODE_URL=http://127.0.0.1:4096 OPENCODE_PASSWORD=... dart run tool/smoke.dart
```

It connects, lists projects and sessions, creates a session, prompts it, folds
the resulting event stream through the same reducer the chat screen uses, and
prints the result. Failures here are server-side facts, not UI problems.

### Tests

`test/` folds real captured event streams from `test/fixtures/events/*.ndjson`.
Those recordings are the reason the reducer is trustworthy: they are actual
server output, not hand-written shapes, so a change in the wire format shows up
as a failing test instead of a blank screen.

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for layering and the
milestone plan, and [docs/API.md](docs/API.md) for the API details this client
depends on — including the parts the published OpenAPI document does not cover.

## Status

Milestones 1–3 are implemented: connect, browse, chat with streaming, and
permission approval. See the architecture document for what is deliberately not
built yet.