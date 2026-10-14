# Running a real OpenCode server on the phone

The app can be a client of an OpenCode server. This document covers the other
direction: running the actual OpenCode server on the Android device, so the
phone is the server rather than the thing being served.

Everything here is verified on a physical device (Android 14, arm64-v8a, MIUI)
with OpenCode 2.0.27 and 2.0.28.

## The obstacle

OpenCode ships one compiled binary per platform:

| Platform package | Builds |
| --- | --- |
| `@opencode/cli-linux-{x64,arm64}` | glibc |
| `@opencode/cli-linux-{x64,arm64}-musl` | musl |
| `@opencode/cli-darwin-{x64,arm64}` | |
| `@opencode/cli-windows-{x64,arm64}` | |

There is no `android-arm64` build, and adding one means teaching Bun to target
Bionic, which is a large job with no upstream payoff. But the musl build is
close enough to run.

The catch is that `-musl` is not statically linked, despite the name. Parsing
the ELF program headers shows:

```
PT_INTERP => /lib/ld-musl-aarch64.so.1
```

Android has no such file, so `execve` fails with `ENOENT` before `main` runs.
Executing it on the device confirms exactly that:

```
/system/bin/sh: /data/local/tmp/opencode: No such file or directory
```

## The fix

Ship the musl loader next to the binary. When the musl loader is executed
directly rather than by the kernel, it takes the program to run as its first
argument — the same shape `ld.so ./program args` has everywhere else:

```sh
ld-musl-aarch64.so.1 /path/to/opencode serve --port 4096
```

Nothing about the OpenCode binary is modified. It stays byte-identical to what
npm publishes, so a version bump is just a new URL and a new checksum, and the
checksum continues to mean "this is what upstream shipped".

One dependency comes along. Bun binaries link against `libstdc++.so.6`, which in
turn needs the `libgcc_s.so.1` unwinder. Alpine publishes musl builds of both.

## The runtime

Four files, ~199 MB in total:

| File | Size | Source |
| --- | --- | --- |
| `bin/opencode` | 205 655 248 | `@opencode/cli-linux-arm64-musl` on npm |
| `lib/ld-musl-aarch64.so.1` | 723 480 | Alpine `musl` |
| `lib/libstdc++.so.6` | 2 754 992 | Alpine `libstdc++` |
| `lib/libgcc_s.so.1` | 133 008 | Alpine `libgcc` |

`dart run tool/fetch_android_runtime.dart` assembles this and writes
`runtime.json` with the URL, size and SHA-256 of every file. The app verifies
each file against that manifest after download, so a corrupted or substituted
binary is rejected before it is ever executed.

## Launching it

Three environment variables matter:

```dart
await Process.start(
  '${runtime}/lib/ld-musl-aarch64.so.1',
  ['${runtime}/bin/opencode', 'serve', '--port', '$port', ...],
  environment: {
    'HOME': workspace.path,          // otherwise it writes to /.local
    'LD_LIBRARY_PATH': '${runtime}/lib',
    'XDG_DATA_HOME': ...,
  },
  workingDirectory: workspace.path,  // becomes the server's project directory
);
```

Without `HOME` the server fails at startup trying to create `/.local/share`.
The working directory matters just as much: OpenCode treats it as the project
it is serving, and that is what shows up in the app's project list.

## Why the server does not run with `--service`

`serve --service` makes the server `chdir` into `$HOME` and pin every session
to it. The `directory` on a request is ignored, so one directory is the whole
world, and the project the app lists is the runtime's own home folder rather
than the folder the user keeps work in. Verified on the device: a session
created with `?directory=<workspace>` came back with `location.directory`
pointing at `$HOME`.

Running without `--service` keeps the working directory the app started the
server in, so the project is the workspace and `directory` is honoured.

Pairing does not depend on the flag. `opencode pair` finds a running server
through the service registry (`<home>/.local/state/opencode/service.json`),
never through the flag itself, so the app writes that registry itself once the
server reports its address and password — `{id, version, url, pid, password}`.
A registry only this app writes is also a registry that cannot be mistaken for
a server belonging to something else, and the app clears it before each start
so anything it finds on a later launch is proof of a server it launched.

`opencode pair --server <url>` is not an alternative: `pair` rejects
`--server` as an unrecognised flag.

## Credentials

The server prints both its address and its password on stdout:

```
server listening on http://127.0.0.1:4197
server password 1gQZb7XsvxRs8TvHBeZeymiYZOVcFXs5y5VXT64IMY0
```

Those two lines are the source; the registry is written from them. A password
found in `<home>/.config/opencode/service.json` is a leftover of `--service`
mode and is not read.

## Verified

```
$ ld.so ./oc --version
opencode v2.0.28

$ ld.so ./oc serve --port 4197 --hostname 127.0.0.1
server listening on http://127.0.0.1:4197
server password 1gQZb7XsvxRs8TvHBeZeymiYZOVcFXs5y5VXT64IMY0
```

Server start to listening: **1.1 s** on the device, from the app's own sandbox.

Every endpoint the app already speaks answers correctly, including auth:

```
GET /api/config   -> [{"type":"directory","path":".../config/opencode"}]
GET /api/session  -> {"data":[],"cursor":{...}}
GET /api/agent    -> build, general, explore, compaction, title, summary, plan
GET /api/provider -> OpenCode Zen, baseURL https://opencode.ai/zen/v1
```

The app connects to it exactly like any other server, which is the point: a
phone-hosted server is not a special case anywhere in the client.

Note the provider list. Zen is present with `apiKey: "public"`, so the local
server can authenticate the same way the user already signs in to opencode.ai.
A separate provider key is not required.

## Constraints worth knowing

- **Size.** ~199 MB. Bundling it in the APK would bloat every install, so it is
  downloaded on demand and verified against the manifest.
- **Where it can run.** Android marks shared storage noexec and FUSE-mounted
  volumes are never executable. The runtime has to live in the app's own
  sandbox, which is fine, but it cannot be run from `/sdcard`.
- **Not Termux.** The whole point of the loader approach is that the app runs
  this itself. Termux is not required, and its absence changes nothing.
- **64-bit only.** `arm64-v8a`. There is no 32-bit Android target.
- **`opencode` spawning itself does not work.** The CLI re-executes
  `process.execPath` to start its own service, and when the loader is the
  executable that path is the loader, so it fails with "cannot load serve".
  The server is therefore started by the app and its registry written by the
  app, so `pair` connects to the running server instead of trying to spawn a
  second one.

## DNS in the runtime

The musl resolver only reads `/etc/resolv.conf`, which does not exist on
Android, so the server cannot resolve any external host: every model call and
`tunnel` request fails with `getaddrinfo ETIMEOUT` while the device itself is
online (verified: raw DNS to 8.8.8.8 from the sandbox answers). No root is
needed to fix it, because the network was never the problem — only the
address book.

The app therefore runs a small CONNECT proxy on loopback next to the server
(see `lib/src/runtime/connect_proxy.dart`, owned by the local-server
controller) and points the server at it with the standard proxy variables.
A proxy address that is an IP literal needs no resolution; the proxy itself
resolves with the platform resolver, which works; TLS passes through
untouched. An earlier attempt at an `LD_PRELOAD` DNS shim is kept as source
under `android/shim` but ships in no APK: preloading broke the server's own
`listen` with `EFAULT`, and the proxy made the shim unnecessary.

## Known gap (closed)

Publishing to the internet is driven by `opencode pair --remote`, and on this
device it used to fail before reaching the relay with `getaddrinfo ETIMEOUT
opentunnel.xyz` — the same blind resolver, not the app or the tunnel. It goes
through the proxy like everything else now.

## Publishing to the internet

`opencode pair --remote` cannot work here, so publishing is the app's own. It
claims a hostname with the service, mints a P-256 key and a certification
request, gets a certificate back, and attaches a bridge. The bridge carries one
visitor's connection at a time over a WebSocket, and the visitor's TLS is
finished on this device.

`opencode pair` still works against the tunnel, because the app writes the
service registry itself rather than asking OpenCode to.

### Why the TLS terminator is not in Dart

`dart:io`'s `SecureServerSocket` hands over its socket only once a handshake is
complete. For a byte relay that is a deadlock rather than an inconvenience: the
server's half of the handshake has to reach the visitor *during* the handshake
or the visitor never answers and the handshake never completes. BoringSSL had
the whole flight ready — nearly 3 kB of ServerHello, certificate and finished —
and there was nowhere to send it, because the stream only existed afterwards.

So the terminator is `SSLEngine`, on the platform
(`android/app/src/main/kotlin/.../tunnel/TlsTerminator.kt`), driven over a
method channel. `SSLEngine` is a state machine that emits each flight as it is
produced, which is what a relay needs and what `dart:io` does not offer.

One session per connection rather than one shared listener: two visitors'
ClientHellos arrive on the bridge indistinguishably, so a shared listener could
not be matched to the visitor it belonged to.

### Two directions of clear text

Once TLS is done with the bytes, both directions are in the clear and they are
opposite. What a visitor sends goes into the socket to the phone-hosted server.
What that server answers comes back out of the pipe and is encrypted on the way
to the visitor. Conflating them hands a visitor its own request back.