# OpenCode server API — notes for the mobile client

Everything here was verified against a live server (`opencode v2.0.18`, port 4096) on 2026-10-13.
Where the published OpenAPI document is incomplete or wrong, the observed behaviour wins and the
difference is called out explicitly.

## Authentication

Every request except `POST /api/pair` and the `/auth/connect/*` page needs:

```http
Authorization: Basic base64("opencode:<server-password>")
```

The username is the literal string `opencode`. The password is the one printed by
`opencode serve` on startup (`server password <value>`) or configured with
`opencode service set password`. The password stored in
`~/.config/opencode/service.json` is **not** the live server password for the background
service — do not use it as a credential source.

Long-lived sessions for browsers and apps are created through pairing:

1. `opencode pair` prints `http://<host>:<port>/auth/connect/<code>` plus a QR code.
2. Opening the link exchanges the code for a session cookie that lasts 30 days.
3. `POST /api/pair` on an authenticated server returns `{ "code", "expires_in" }` so a client
   can drive the same flow.

Changing the server password invalidates every session.

## Connection modes from a phone

| Setup | Server URL | Notes |
| --- | --- | --- |
| USB device | `http://127.0.0.1:4096` | `adb reverse tcp:4096 tcp:4096` |
| Emulator | `http://10.0.2.2:4096` | host loopback alias |
| LAN device | `http://<host-lan-ip>:4096` | `opencode service set hostname 0.0.0.0` |
| Anywhere | OpenTunnel remote address | `opencode pair --remote`, end-to-end encrypted |

## Scoping requests to a project

Most list and write endpoints accept a `directory` query parameter holding an absolute path.
The server echoes the active location on every event (`location.directory`), so the client can
group live events by project without extra bookkeeping.

## Event stream

`GET /api/event` returns `text/event-stream`. Each SSE `data:` frame is one JSON envelope:

```json
{
  "id": "evt_133470811001g14MIRXwz22X27",
  "created": 1791861655569,
  "type": "session.text.delta",
  "location": { "directory": "C:\\Users\\vitaly\\dev\\_demo" },
  "data": { "sessionID": "ses_…", "assistantMessageID": "msg_…", "ordinal": 0, "delta": "PING-OK" },
  "durable": { "aggregateID": "ses_…", "seq": 0, "version": 1 }
}
```

`durable` is present only for events that are persisted and replayable; `seq` is monotonic per
session aggregate and is the right cursor for catching up after a reconnect.

The OpenAPI schema types this payload as a bare `string` (`V2EventEncoded`) and lists no event
types, so the type table below was recovered by recording a live session.

### Observed event types

| Type | `data` payload |
| --- | --- |
| `server.connected` | — (stream marker) |
| `project.updated` | project info |
| `session.created` | `{ sessionID, slug, version, projectID, location, subpath }` |
| `session.renamed` | `{ sessionID, title }` |
| `session.instructions.updated` | instruction entries |
| `session.inbox.enqueued` | queued prompt metadata |
| `session.inbox.delivered` | delivery result |
| `session.execution.started` | `{ sessionID }` |
| `session.execution.succeeded` | `{ sessionID }` |
| `session.execution.interrupted` | `{ sessionID }` |
| `session.step.started` | `{ sessionID, assistantMessageID }` |
| `session.step.streamed` | step progress |
| `session.step.ended` | step summary |
| `session.step.failed` | `{ sessionID, … }` |
| `session.retry.scheduled` | `{ sessionID, assistantMessageID, attempt, at, error{type, message} }` — an attempt failed and another is scheduled; the execution is still alive |
| `session.text.started` | `{ sessionID, assistantMessageID, ordinal }` |
| `session.text.delta` | `{ sessionID, assistantMessageID, ordinal, delta }` |
| `session.text.ended` | `{ sessionID, assistantMessageID, ordinal, text }` |
| `session.tool.input.started` | `{ sessionID, assistantMessageID, id, name }` |
| `session.tool.input.ended` | `{ …, text }` (raw JSON arguments) |
| `session.tool.called` | `{ …, id, input, executed }` |
| `session.tool.progress` | `{ …, id, metadata }` |
| `session.tool.success` | `{ …, id, content[], metadata }` |
| `session.tool.failed` | `{ …, id, error }` |
| `session.usage.updated` | `{ sessionID, cost, tokens{input,output,reasoning,cache{read,write}} }` |
| `permission.asked` | `{ id, sessionID, action, resources[], save[], source{type,messageID,id} }` |
| `permission.replied` | `{ sessionID, requestID, reply }` |
| `shell.created` / `shell.exited` | shell info |
| `provider.updated`, `model.updated`, `agent.updated`, `command.updated`, `skill.updated`, `plugin.updated`, `reference.updated`, `websearch.updated`, `integration.updated` | cache invalidation signals |

Unlisted `session.*` families seen in the wild and expected by the client reducer:
`session.reasoning.*`, `session.error`, `session.deleted`. The client must tolerate unknown
types by ignoring them rather than failing.

## Core request/response shapes

- `GET /api/session?directory=&limit=&order=&search=&cursor=` → `{ data: Session.Info[], cursor }`.
  `Session.Info` carries `id`, `title`, `projectID`, `agent`, `model`, `cost`, `tokens`,
  `time{created,updated,idle,viewed,archived}`, `location`, `permissions`, `revert`.
- `GET /api/session/{id}/message?limit=&order=&type=` → `{ data: Session.Message.Info[], cursor }`.
- `POST /api/session/{id}/prompt` body: `{ text, files?, agents?, skills?, delivery?, resume? }`.
- `POST /api/session/{id}/interrupt?resume=` → `{ interrupted: bool }`.
- `POST /api/session/{id}/permission/{requestID}/reply` body: `{ "reply": "once" | "always" | "reject" }`, `204` on success.
- `POST /api/session` body: `{ parentID?, title? }`.
- `GET /api/info` → `{ version, pid, urls[], paths }`.

## Agents

- `GET /api/agent?location[directory]=` → `{ location, data: Agent.Info[] }`.
  `location` is a **deep object**, not a plain string: `?directory=` is silently
  ignored, the accepted form is `?location[directory]=`. `Agent.Info` carries
  `id`, `name`, `mode` (`primary` | `subagent`), `hidden`, `description`,
  `color`, `model`, `steps`, `permissions`.
- `POST /api/session/{id}/agent` body: `{ agent }`, `204` on success.

Two behaviours verified against the live service on 2026-10-13:

- **`/api/agent` returns far more agents than belong in a picker.** On one
  machine it answered with 41 entries of which only 2 were conversation
  partners (`build`, `plan`); the rest were `subagent` workers and three hidden
  bookkeeping agents (`compaction`, `title`, `summary`). The client filters to
  `!hidden && mode == "primary"`.
- **`POST /api/session/{id}/agent` validates nothing.** It answers `204` for any
  string at all, including ids that do not exist (`nope-xyz` was accepted and
  stored). A client can therefore write a session into an agent that does not
  exist; the offered list must come from `/api/agent`, never from free text.

A session that has never run reports no `agent` field. That is normal, not an
error: the server assigns the default agent on the first turn.

## Client code generation

The server publishes its OpenAPI document at `https://opencode.ai/v2/openapi.json`
(`openapi: 3.1.0`, 284 schemas). It generates cleanly with `openapi-generator-cli` using the
`dart-dio` generator, but the generator's `dart` library option no longer exists in 7.26 —
use the `dart-dio` generator id instead. Regenerate with `tool/generate_api.sh`.