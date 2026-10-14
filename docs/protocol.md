# Tunnel protocol

How this phone publishes its server to the internet through the OpenTunnel
service (`https://opentunnel.xyz`), and the exact bytes both halves speak.
Everything here was recovered from the service's behaviour and is exercised
by tests that speak to fakes, never to the service itself.

The shape of the whole thing: the phone claims a hostname, proves it holds a
key by getting a certificate signing request signed, attaches a bridge over a
WebSocket, and finishes each visitor's TLS locally. The service only ever sees
hostnames, an opaque token, and encrypted bytes. The private key never leaves
the device.

## Roles

| Side | Does |
| --- | --- |
| This app | Generates the key, asks for the certificate, attaches the bridge, terminates visitor TLS, relays the cleartext to the server on this phone |
| The service | Issues hostnames and certificates, routes visitors to the attached bridge |
| A visitor | Opens TLS to the hostname, talks HTTP to the phone's server as if it were local |

## HTTP API

Base URL `https://opentunnel.xyz`. Auth is `Authorization: Bearer <token>`
everywhere except claiming, which is what hands the token out. The token is
shown exactly once; losing it means losing the tunnel.

| Call | Effect |
| --- | --- |
| `POST /api/tunnel` `{}` | Claims a tunnel. Answers `{ tunnel{id, hostname, …}, token }`. The body must be an empty object — no body at all is rejected without explanation. Never retried on timeout: the tunnel may already exist on the service side with nobody holding its token. |
| `GET /api/tunnel/{id}` | Reads the tunnel: id, hostname, online/offline, certificate id if any. |
| `POST /api/tunnel/{id}/certificate` `{csr}` | Asks for the certificate signing request to be signed. Answers a state: `challenge`, `issuing`, `ready` (with certificate + chain + expiry) or `failed` (with reason). |
| `GET /api/tunnel/{id}/certificate` | Polls the same state. Polled every 2 seconds for up to 3 minutes; issuance is seconds when it works. |
| `DELETE /api/tunnel/{id}` | Releases the tunnel and everything issued against it. Called only when the user stops publishing for good, never on a plain stop. |

Retry rules are part of the contract: repeatable reads retry on 429/500–504,
claiming never retries on 429/503/521–523/525 (a timed-out claim may already
exist server-side), deletion never retries on the same set. Cloudflare 5xx
bodies are HTML, so those statuses are translated to sentences. `Retry-After`
is honoured, capped, with jitter.

## Identity

- P-256 key, generated locally with platform entropy. PKCS#8 PEM on disk,
  sent nowhere.
- PKCS#10 certification request sent as bare base64 DER (no PEM armor — the
  service fails armored input at parse, before looking at the ASN.1):
  `CN=<hostname>` plus a `subjectAltName` with the host and `*.<hostname>`
  (routes are one label in front of the host; without the wildcard every route
  is refused). The SAN rides directly as the attribute rather than wrapped in
  an `extensionRequest` carrying an `Extensions` SEQUENCE OF — not the textbook
  layout, but the one the service issues against, verified live end to end
  (claim → request → poll to ready → delete). ECDSA with SHA-256, parameters
  omitted. The request signs exactly the bytes sent.
- The ASN.1 subset is hand-written (`lib/src/runtime/tunnel/der.dart`):
  shortest-form DER, no optional empties, byte-for-byte assertable in tests.
  It is not a general library and does not try to be one. Pointycastle has
  the CSR skeleton but no builder for the SAN extension, so depending on it
  would leave two encoders in one request; one local encoder is the smaller
  risk, and an independent-decoder test plus a past `openssl -verify` keep
  it honest.

Both the identity and the issued certificate persist in the app's support
directory (`opentunnel/`), written atomically before they are needed, so an
interrupted provisioning resumes instead of re-claiming. A hostname somebody
may have bookmarked must not silently change.

The private key file is the one secret here that root can carry away: sandbox
UID isolation and file-based encryption stop other apps and a powered-off
device, but a live root read takes the key, the token and the certificate
together — and with the token alone it could attach its own bridge anyway.
Moving the key into the Keystore would change that only cosmetically (root
can use Keystore entries as an oracle), while splitting certificate issuance
across the platform channel, so the key stays a file and this paragraph stays
honest about it.

## Bridge

`wss://opentunnel.xyz/api/tunnel/{id}/connect`, WebSocket subprotocol
`opentunnel` (offering only it is the whole version negotiation).

Two frame kinds share the socket:

- **Text frames** are JSON control messages (see below).
- **Binary frames** are connection data: big-endian `u32` connection id
  followed by the payload. Payloads over 32 KiB are a protocol violation, not
  a large request.

Flow: connect → send `attach` (`token`, `routes`, `max_conns`, client
version) → wait up to 10 s for `attached` (session id, heartbeat and idle
intervals) → serve. Heartbeats go out on the service's interval. A dropped
socket reconnects with jittered backoff; a refused token or an unissued
certificate does not retry. Slow consumers are cut off by the service, which
is why the client never lets its own queues grow: held frames, waiting bytes
and connections are all bounded.

Control messages (`type` first, unknown fields ignored, unknown types refused):

| Type | Direction | Meaning |
| --- | --- | --- |
| `attach` | app → service | Claim routes with the token. |
| `attached` | service → app | Accepted: session, routes held, heartbeat/idle intervals. |
| `attach_error` | service → app | Refused: `code`. `bad_token` and `cert_not_ready` are final. |
| `open` | service → app | A visitor is connecting: connection id, peer, SNI (which picks the route), ALPN. Its ClientHello follows in binary frames. |
| `ping` / `pong` | both ways | Heartbeat, echoing `time_sent`. |
| `drain` | service → app | Shedding load; connections should end. |
| `end` | both ways | Half-close for one connection. |
| `reset` | both ways | Abort with a code. The app refuses with `unknown_route` (wrong name) or `too_many_connections` (over the advertised cap). |

Only the tunnel host itself (`@`) and exactly one label in front of it are
served; anything deeper is refused. Answering a deeper name would mean serving
a host this device has no business serving.

## TLS termination

The visitor's TLS is finished on the phone, against the issued certificate.
`dart:io` cannot do this — its secure socket only exists after the handshake,
and the handshake needs the server's flights to reach the visitor *during* it.
So termination is `javax.net.ssl.SSLEngine` on the platform
(`android/.../tunnel/TlsTerminator.kt`), driven over a method channel, one
engine per connection on a single thread.

Per connection: `start` → feed visitor bytes → handshake flights flow back →
`ready` → application bytes decrypt into the socket to the phone's server and
back → `closed`/`failed` at the end. Bytes arriving before a pipe exists are
held, bounded, and fed first. The handshake has a 20 s deadline; a visitor
that says nothing must not hold a slot forever.

What the service sees of all this is ciphertext. What the phone's server sees
is plain HTTP, exactly as if the visitor were on loopback.

## And `opencode pair --remote`?

That is the official flow and it stays broken here for an unrelated reason
(the bundled runtime cannot resolve the relay's hostname — see
[ANDROID_RUNTIME.md](ANDROID_RUNTIME.md)). This tunnel replaces only the
transport: `opencode pair` against the tunnelled address still mints the code,
because pairing reads the service registry the app writes itself.
