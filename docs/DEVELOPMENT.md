# Development

How to work on this project from a machine with no Flutter on it yet, and what
this repo learned the hard way. For the product side see
[ARCHITECTURE.md](ARCHITECTURE.md); for the phone-hosted server see
[ANDROID_RUNTIME.md](ANDROID_RUNTIME.md).

## Toolchain

- Flutter 3.47+ / Dart 3.13+ (pinned by `pubspec.yaml`: `sdk: ^3.13.5`)
- JDK 17 — the system default is often 11, and AGP 9.x refuses it
- Android SDK with platform 36 and build-tools 36

The toolchain does not have to live anywhere specific, but every path below
must be known in one place. On the machine this was written on, everything
sits on the root partition because `/home` was full:

| What | Path |
| --- | --- |
| Flutter SDK | `/opt/flutter` |
| Dart/Flutter pub cache | `/opt/pub-cache` (`PUB_CACHE`) |
| Gradle home | `/opt/gradle-home` (`GRADLE_USER_HOME`) |
| Android SDK | `/opt/android-sdk` (`ANDROID_HOME`) |
| JDK | `/usr/lib/jvm/java-17-openjdk` (`JAVA_HOME`) |

`flutter`, `dart`, `adb` and `sdkmanager` are symlinked into `~/.local/bin`,
so they work from any shell without rc files. `~/.gradle` is a symlink to the
Gradle home, so a build started without `GRADLE_USER_HOME` still finds its
cache instead of downloading the internet twice.

`android/local.properties` (SDK + Flutter paths) is git-ignored; create it
per machine:

```ini
sdk.dir=/opt/android-sdk
flutter.sdk=/opt/flutter
```

## Commands

```sh
flutter pub get
flutter analyze        # must be clean
flutter test           # unit tests over recorded fixtures, must be green
flutter build apk --debug
```

Check the APK hash after building (`sha1sum
build/app/outputs/flutter-apk/app-debug.apk`): **`flutter install` does not
rebuild** — it installs whatever is already in `build/`. The order is always
build first, then install:

```sh
adb -s <device-id> install -r build/app/outputs/flutter-apk/app-debug.apk
```

`flutter run -d <device-id>` is the hot-reload loop (`r` reload,
`R` restart). Kotlin changes and the manifest always need a full rebuild.

## The device

- `adb devices` must list the phone; `flutter devices` must show it as
  `android-arm64`.
- Reaching a desktop server from the phone: `adb reverse tcp:4096 tcp:4096`,
  then `127.0.0.1:4096` in the app. The phone-hosted server prefers a sticky
  port of its own, so the two do not fight over 4096.
- Developer options on the phone: "Install via USB" and "USB debugging
  (Security settings)". Without the second, `adb shell input` is silently
  ignored. Even with both, each `adb install` can pop a system confirmation;
  it goes away with:

```sh
adb shell settings put global verifier_verify_adb_installs 0
adb shell settings put global package_verifier_enable 0
```

- Screenshots: `adb shell screencap -p /sdcard/x.png` + `adb pull`. A
  picture-in-picture window blocks the capture (0-byte PNG); close it.
  `uiautomator dump` sees nothing — Flutter draws on a canvas.

## Gotchas learned here

- `android/gradle.properties` asks for `-Xmx8G`. On an 11 GB machine that,
  plus two Kotlin daemons, pushed everything into swap and stalled the whole
  system. The override lives in `GRADLE_USER_HOME/gradle.properties`
  (`-Xmx3G`, `workers.max=4`), never in the repo.
- The first build downloads Gradle 9.3.1, AGP/Kotlin, and NDK 28 (~2.2 GB,
  required by the bundled `libldmusl.so`). Later builds reuse the cache.
- `cupertino_icons` is in `pubspec.yaml` but used nowhere; `qr`,
  `material_color_utilities` and `test_api` are pinned transitively by the SDK.
- `tool/smoke.dart` (`dart run`) is currently broken: `lib/src/data/api.dart`
  imports `package:flutter/foundation.dart`, which plain `dart run` cannot
  load. The live-server check needs a `flutter test` harness instead.
- Docs rot: `ARCHITECTURE.md` mentions `DartIoPlainConnect` (never built) and
  `FLAG_SECURE` on the session screen (not in the code). Trust the code.
