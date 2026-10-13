# Architecture

## Goal

A real Android client for an OpenCode server: connect from a phone, watch and drive sessions
live, answer permission requests, read diffs. Quality bar is a public product — typed code,
tests, no secrets in logs.

## Layers

```
lib/
  api/            generated OpenAPI client (packages/opencode_api/) + hand-written transport
  core/           theme, router, result/error types, logging
  features/
    connect/      server url + password, QR pairing, connection test
    projects/     project list, directory switch
    sessions/     session list, search, live status badges
    chat/         message timeline, streaming reducer, composer, model/agent picker
    permissions/  permission inbox + reply sheet + local notification
    diff/         session diff viewer
  state/          Riverpod providers, event bus, connection lifecycle
```

Dependency direction is strictly downward: `features → state → api → core`. No feature imports
another feature; cross-feature navigation goes through `core/router`.

## State management

Riverpod with `AsyncNotifier`. Three long-lived providers own the session:

- `connectionProvider` — current server, auth headers, reachability, reconnect backoff.
- `eventStreamProvider` — a single `Stream<ServerEvent>` fed by one SSE subscription. Fan-out
  is done in the provider, not by opening N subscriptions, because the server sends the whole
  event stream to every client.
- `sessionTimelineProvider(sid)` — per-session immutable timeline built by folding events.

### Timeline reducer

The server streams deltas (`session.text.delta`) that must be merged into blocks owned by
`(assistantMessageID, ordinal)`. The reducer is a pure function:

```dart
Timeline applyEvent(Timeline state, ServerEvent event)
```

It is the most heavily unit-tested part of the codebase because it is driven entirely by the
recorded fixtures in `test/fixtures/events/*.ndjson` (real captures, not invented payloads).
Unknown event types must be ignored rather than throw, since the server adds types without
notice.

## API client

The published OpenAPI document generates a typed `dart-dio` client covering all 29 API groups
and 471 models. It is regenerated with `tool/generate_api.sh` and committed under
`packages/opencode_api`. Hand-written code on top:

- `AuthInterceptor` — attaches `Authorization: Basic …`.
- `EventStreamClient` — SSE over `dio` with a response `Stream`, reconnect with backoff, and
  `durable.seq` based gap detection.
- `DartIoPlainConnect` — `HttpClient` based SSE adapter. Avoids the buffering behaviour that
  makes some SSE clients stall on Android.

## Security

- Password stored in `flutter_secure_storage` (Android Keystore), never in `SharedPreferences`.
- `FLAG_SECURE` on the session screen so the chat is not captured in screenshots or the
  recents preview.
- Passwords redacted in `log()` output; a debug-only banner in dev builds.
- Release builds have no logging that includes request bodies.

## Selection sheets hold their own state

`showModelPicker` and `showAgentPicker` are opened in their own route. A `setState` in the screen
behind the sheet does **not** rebuild the sheet, so a sheet that read the current value from its
`widget.current` showed a tick on whatever it was opened with and never moved it, while the
underlying value did change. Both sheets therefore keep the selection in their own `State`,
move it optimistically on tap, and revert to the incoming value if the request fails.

## Known constraints

- **Background execution.** Android may kill an app's socket when it is backgrounded. Live
  updates therefore stop when the app is suspended; v1 compensates with a polling fallback and
  a local notification when a permission request arrives. A foreground service is out of scope.
- **No Dart SDK from OpenCode.** The generated client is the only supported path to types.
- **PTY terminal** is phase 2: `/api/pty/{id}/connect` is a websocket, which needs its own
  connection handling separate from the REST/SSE client.
- **The server validates almost nothing.** `POST /api/session/{id}/agent` answers `204` for any
  string, including agent ids that do not exist, and `POST /api/session/{id}/model` likewise
  accepts an unknown reasoning variant and silently does nothing. Offered values always come from
  a list endpoint (`/api/agent`, the model's own `variants`) and are never typed by hand.

## Milestones

1. **M1 — Connect + read.** Server list, connection test, projects and sessions browsing with
   live status. Proves auth, the event stream and the design system.
2. **M2 — Chat.** Timeline reducer, streaming text, tool cards, composer, stop, model and agent picker.
3. **M3 — Permissions.** Inbox, reply sheet, notification, "always" persistence.
4. **M4 — Diff + polish.** Diff viewer, search, theming, accessibility, release build.
5. **M5 — Terminal.** Websocket PTY, if the client shape proves out.