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
types. The table below merges live captures with the 2.0.28 schema sources: every row is
either recorded on a wire or read out of the server's own event definitions. The stream
itself is volatile by contract (the OpenAPI summary says so outright): a slow consumer
overflows and fails the stream, and events missed during a disconnection never replay.
`seq` is monotonic per session aggregate; a jump means holes, and only a REST refetch
repairs them.

### Observed event types

| Type | `data` payload | Client |
| --- | --- | --- |
| `server.connected` | — (stream marker) | ignored |
| `project.updated` | project info | refetches the project list |
| `session.created` | `{ sessionID, slug, version, projectID, location, subpath }` | refetches the session list |
| `session.renamed` | `{ sessionID, title }` | renames in place |
| `session.deleted` | `{ sessionID }` | refetches the session list |
| `session.moved`, `session.forked` | `{ sessionID, … }` | ignored (visible on next list refetch) |
| `session.viewed`, `session.permissions`, `session.synthetic` | `{ sessionID, … }` | ignored (other clients' bookkeeping) |
| `session.agent.selected`, `session.model.selected` | `{ sessionID, … }` | shown after history reload |
| `session.metadata.updated` | `{ sessionID, … }` | ignored |
| `session.skill.activated` | `{ sessionID, … }` | ignored |
| `session.instructions.updated` | instruction entries | ignored |
| `session.inbox.enqueued` | queued prompt metadata | ignored (prompt runs normally) |
| `session.inbox.delivered` | delivery result | ignored |
| `session.inbox.cancelled`, `session.inbox.delivery.changed` | `{ sessionID, … }` | ignored |
| `session.execution.started` | `{ sessionID }` | spinner on |
| `session.execution.succeeded` | `{ sessionID }` | spinner off |
| `session.execution.interrupted` | `{ sessionID, reason }` | spinner off |
| `session.execution.failed` | `{ sessionID, error{type, message, status?, response?} }` | spinner off, error shown |
| `session.step.started` | `{ sessionID, assistantMessageID }` | ignored |
| `session.step.streamed` | step progress | ignored |
| `session.step.ended` | step summary | ignored |
| `session.step.failed` | `{ sessionID, … }` | ignored |
| `session.retry.scheduled` | `{ sessionID, assistantMessageID, attempt, at, error{type, message} }` — an attempt failed and another is scheduled; the execution is still alive | retry banner with the reason |
| `session.text.started` | `{ sessionID, assistantMessageID, ordinal }` | assistant block |
| `session.text.delta` | `{ sessionID, assistantMessageID, ordinal, delta }` | streamed text |
| `session.text.ended` | `{ sessionID, assistantMessageID, ordinal, text }` | final text |
| `session.reasoning.started/delta/ended` | like text | collapsed reasoning |
| `session.tool.input.started` | `{ sessionID, assistantMessageID, id, name }` | pending tool card |
| `session.tool.input.delta/ended` | streamed/raw arguments | ignored (input shown when called) |
| `session.tool.called` | `{ …, id, input, executed }` | running tool card |
| `session.tool.progress` | `{ …, id, metadata }` | ignored |
| `session.tool.success` | `{ …, id, content[], metadata }` | completed tool card |
| `session.tool.failed` | `{ …, id, error }` | errored tool card |
| `session.usage.updated` | `{ sessionID, cost, tokens{input,output,reasoning,cache{read,write}} }` | totals footer |
| `session.usage.recorded` | internal projector input, never reaches clients | n/a |
| `session.message.content.updated` | replay-only legacy shape | ignored |
| `session.compaction.started/delta/failed` | compaction progress | ignored |
| `session.compaction.ended` | summary (not the messages) | refetches history |
| `session.shell.started/ended` | PTY lifecycle (terminal is a later milestone) | ignored |
| `session.revert.staged/committed/cleared` | checkpoint lifecycle | ignored |
| `session.agent.selected`, `session.model.selected` | `{ sessionID, … }` | shown after history reload |
| `session.metadata.updated`, `session.skill.activated` | `{ sessionID, … }` | ignored |
| `session.inbox.cancelled`, `session.inbox.delivery.changed` | `{ sessionID, … }` | ignored |
| `session.moved`, `session.forked` | `{ sessionID, … }` | visible on next list refetch |
| `session.viewed`, `session.permissions`, `session.synthetic` | bookkeeping | ignored |
| `session.status`, `session.idle` | ephemeral TUI status feed, never published in 2.0.28 | ignored (durable execution events are the source) |
| `permission.asked` | `{ id, sessionID, action, resources[], save[], source{type,messageID,id} }` | inbox + sheet |
| `permission.replied` | `{ sessionID, requestID, reply }` | clears the inbox entry |
| `form.created` | `{ form{id, sessionID, title, fields[] } }` | inbox + sheet (the agent stalls until answered) |
| `form.replied`, `form.cancelled` | `{ id, sessionID }` | clear the inbox entry |
| `tui.command.execute`, `tui.prompt.append`, `tui.session.select`, `tui.toast.show` | TUI remote control | ignored |
| `vcs.branch.updated` | branch info | ignored (nothing shows branches) |
| `worktree.resolved`, `worktree.updated` | worktree info | ignored (no worktree UI) |
| `location.shutdown` | server going down | ignored |
| `installation.update`, `installation.updated` | updater state | ignored |
| `credential.switched`, `credential.updated` | auth internals | ignored |
| `filesystem.changed` | file watcher | ignored (no file browser) |
| `pty.created/updated/exited/deleted` | PTY lifecycle (terminal is a later milestone) | ignored |
| `shell.created` / `shell.exited` / `shell.deleted` | PTY info | ignored |
| `provider.updated`, `model.updated`, `agent.updated`, `command.updated`, `skill.updated`, `plugin.updated`, `reference.updated`, `websearch.updated`, `integration.updated`, `mcp.resources.changed`, `mcp.status.changed` | cache invalidation signals (only status/resources changes reach SSE) | ignored (pickers refetch on open) |
| `rpc.*` | plugin RPC frames | ignored |

There is no `session.updated` and no `session.error` on the wire (verified against the
2.0.28 schema): renames, deletes and failures all have their own types, and the client
must tolerate unknown types by ignoring them rather than failing.

## Core request/response shapes

- `GET /api/session?directory=&limit=&order=&search=&cursor=` → `{ data: Session.Info[], cursor }`.
  `Session.Info` carries `id`, `title`, `projectID`, `agent`, `model`, `cost`, `tokens`,
  `time{created,updated,idle,viewed,archived}`, `location`, `permissions`, `revert`.
- `GET /api/session/{id}/message?limit=&order=&type=` → `{ data: Session.Message.Info[], cursor }`.
- `POST /api/session/{id}/prompt` body: `{ text, files?, agents?, skills?, delivery?, resume? }`.
- `POST /api/session/{id}/interrupt?resume=` → `{ interrupted: bool }`.
- `POST /api/session/{id}/permission/{requestID}/reply` body: `{ "reply": "once" | "always" | "reject" }`, `204` on success.
- `POST /api/session/{id}/form/{formID}/reply` body: `{ "answer": {key: value} }`, `204` on success.
- `GET /api/session/{id}/form`, `GET /api/session/{id}/form/{formID}`, `GET /api/form` exist but the client never calls them: open forms arrive as `form.created` events, which is also the only timely source.

The tunnel service (`https://opentunnel.xyz`) is a different API from the OpenCode
server above and is documented separately in [protocol.md](protocol.md).
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