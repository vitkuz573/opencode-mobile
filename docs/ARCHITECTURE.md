# Architecture

## Goal

A real Android client for an OpenCode server: connect from a phone, watch and drive sessions
live, answer permission requests and questions, read usage — and optionally host the server
on the phone and publish it. Quality bar is a public product: typed code, tests, no secrets
in logs.

## Layers

```
lib/src/
  data/       HTTP API client, SSE transport, models, pairing, stats, log
  runtime/    phone-hosted server: paths, installer, process handle, CONNECT
              proxy, output parsers — plus tunnel/: identity, API, protocol,
              bridge, pipes, terminator interface, controller, store
  state/      Riverpod providers, timeline reducer, connection and server
              controllers
  ui/         screens, sheets, widgets; main.dart wires ProviderScope + app

android/app/src/main/kotlin/.../
  MainActivity.kt          engine + two method channels (keepalive, tunnel_tls)
  KeepAliveService.kt      foreground service holding the server process
  tunnel/                  TLS termination on SSLEngine (TlsTerminator.kt)
                           and its channel (TunnelTlsChannel.kt)
```

Dependency direction is downward with one documented exception: `ui` builds on
`state`, `data` and `runtime` directly; `state` owns the controllers and folds
events using `data` and `runtime`; `data` is dependency-free transport plus
models. The exception is the tunnel controller: it lives in `runtime/tunnel`
with the machinery it drives, but it is Riverpod state and reads the shared
providers. Nothing imports `ui` except the app entry, and screens navigate
with explicit pushes rather than through a router, so every route transition
is visible at the call site. Inside the tunnel the sideways dependencies go
through narrow interfaces (`TlsTerminator`, `VisitorPipeFactory`,
`BridgeSocketOpener`), which is what lets every behaviour around the platform
and the network be unit-tested with fakes.

Native code exists for exactly two things Dart cannot do: keep the process
alive and finish a TLS handshake mid-flight.

## State management

Riverpod, hand-written providers (no code generation):

- `connectionProvider` — the active connection. Starts disconnected every
  launch, by decision: a server is always picked explicitly, never restored.
- `liveEventsProvider` — one SSE subscription for the whole app, fanned out
  to screens. `eventLogProvider`/`eventsProvider` accumulate it (capped).
- `localServerProvider` — the phone-hosted server: install, start/stop,
  status, CONNECT proxy lifecycle, tunnel controller.
- Derived providers fold the log: `runningSessionIdsProvider`,
  `sessionRenamesProvider`, `permissionInboxProvider`, `formInboxProvider`,
  `sessionMutationsProvider`/`projectMutationsProvider` (REST lists refetch
  when the bus reports a structural change).
- `appLockProvider` — biometric gate state; `RootGate` shows the lock screen
  over everything until one ceremony passes, and relocks on backgrounding.

### Timeline reducer

The server streams deltas (`session.text.delta`) that must be merged into blocks owned by
`(assistantMessageID, ordinal)`. The reducer is a pure function:

```dart
Timeline applyEvent(Timeline state, ServerEvent event)
```

It is the most heavily unit-tested part of the codebase because it is driven by the
recorded fixtures in `test/fixtures/events/*.ndjson` (real captures, not invented payloads).
Unknown event types are ignored rather than throw, since the server adds types without
notice. Retries set attempt + reason (cleared by real progress); terminal failures stop
the run and keep the reason.

### The event stream is volatile

The server says so outright: a slow consumer overflows and fails the stream, and events
missed during a disconnection never replay. The client reconnects with backoff, and the
chat repairs holes two ways: a durable-`seq` jump refetches history, and the reload
button refetches it on demand. There is no gap-free guarantee to offer, so none is
claimed.

## API client

Hand-written `dio` client in `lib/src/data/api.dart` covering exactly what the app
uses (info, projects, sessions, messages, prompt, interrupt, agent/model, permissions,
forms, pairing, usage, providers). No generated code, no checked-in spec to drift.

- Auth is per profile: `Authorization: Basic opencode:<password>` or a pairing
  session cookie. Passwords rotate (the phone server mints a new one per
  start); connecting to a loopback profile re-reads the live password first.
- `EventStream` — SSE over `dio` with `ResponseType.stream`, an incremental
  frame parser, bounded exponential backoff, and a terminal `failed` state
  after 6 attempts.

## Security

- Secrets (passwords, pairing cookies, tunnel token and private key) live in
  `flutter_secure_storage` (Android Keystore) or the app-private directory.
  Never in `SharedPreferences`, never in logs; the on-disk log mirrors only
  what the screen already shows.
- The tunnel private key never leaves the device; only the certificate signing
  request does. TLS is terminated on the phone against the issued certificate.
- The bridge serves the tunnel host and one label in front of it, never
  deeper. Connections, held frames, waiting bytes and handshakes are all
  bounded; heartbeats and idle timers come from the service.
- The app lock (Settings → Security) gates the whole app behind biometrics
  with the device PIN as fallback. The flag lives next to the secrets it
  guards.

## Routing rule

A successful connect always lands on the session list (`popUntil(isFirst)`),
wherever it started: tapping a server, adding one, or opening the phone's
own. Tapping the already-active server enters the app instead of ignoring the
tap. There is no screen that needs a server to justify opening settings.

## Selection sheets hold their own state

`showModelPicker` and `showAgentPicker` are opened in their own route. A `setState` in the screen
behind the sheet does **not** rebuild the sheet, so a sheet that read the current value from its
`widget.current` showed a tick on whatever it was opened with and never moved it, while the
underlying value did change. Both sheets therefore keep the selection in their own `State`,
move it optimistically on tap, and revert to the incoming value if the request fails.
The permission and form sheets follow the same shape: own state, send, error, close.

## Known constraints

- **Background execution.** The server is a child process: if Android kills the
  app, it takes the server with it. A foreground service holds the app while it
  is backgrounded; a relaunch rejoins a still-running server by probing its
  registry instead of reporting it gone.
- **No Dart SDK from OpenCode.** There is no supported typed client; the
  hand-written one above is it, verified against fixtures and the versioned
  schema sources.
- **The server validates almost nothing.** `POST /api/session/{id}/agent` answers `204` for any
  string, including agent ids that do not exist, and `POST /api/session/{id}/model` likewise
  accepts an unknown reasoning variant and silently does nothing. Offered values always come from
  a list endpoint (`/api/agent`, the model's own `variants`) and are never typed by hand.
- **PTY terminal** is not built: shell/pty events are documented and ignored.

## What is deliberately not built

Diff viewer, search, theming/accessibility polish, release build, PTY terminal,
multi-window, widgets. The tunnel replays nothing and stores nothing beyond
its own identity; visitors are relayed, never inspected.
