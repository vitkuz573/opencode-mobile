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

## Verified

```
$ ld.so ./oc --version
opencode v2.0.28

$ ld.so ./oc serve --port 4197 --hostname 127.0.0.1
server listening on http://127.0.0.1:4197
server password 1gQZb7XsvxRs8TvHBeZeymiYZOVcFXs5y5VXT64IMY0
```

Server start to listening: **1.1 s** on the device.

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