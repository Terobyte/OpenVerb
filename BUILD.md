# Building OpenVerb

This is the long version of the install instructions in the [README](README.md). Read this if something failed, or if you want a redistributable `.app` bundle instead of just a binary.

## Prerequisites

- macOS 13.0+ on Apple Silicon
- Xcode 15+ (for the SwiftUI app and the macOS SDK)
- Command Line Tools: `xcode-select --install`
- CMake 3.24+: `brew install cmake`
- Git LFS (only if you plan to commit model weights): `brew install git-lfs`
- ~10 GB of free disk while building

## 1. Clone the repo

OpenVerb pulls in `llama.cpp` and `nlohmann/json` as submodules.

```bash
git clone --recurse-submodules https://github.com/<your-fork>/OpenVerb.git
cd OpenVerb
```

If you forgot `--recurse-submodules`:

```bash
git submodule update --init --recursive
```

## 2. Build the C++ engine

The engine is a standalone executable that the Swift app spawns over a Unix socket.

```bash
cd engine
cmake -B build-release \
      -DCMAKE_BUILD_TYPE=Release \
      -DLLAMA_METAL=ON
cmake --build build-release -j
cd ..
```

You should get `engine/build-release/openverb-engine`. Run it with `--help` to confirm.

## 3. Get the model weights

OpenVerb runs Gemma 4 E2B (audio + text). Weights are not in the repo — they're ~5 GB.

```bash
./scripts/download-model.sh
```

The script downloads the GGUF + mmproj files to `~/.openverb/models/` with resumable transfers and SHA256 verification. If you already have them somewhere else, point `OPENVERB_MODEL_DIR` at that directory.

## 4. Build the Swift app

### Option A — `swift build` (fastest, gives you a binary)

```bash
cd app
swift build -c release
./.build/release/OpenVerb
```

Good for development. You can't ship the result — there's no `.app` bundle, no Info.plist linkage, no entitlements. macOS will refuse to grant Accessibility to a raw Mach-O.

### Option B — Xcode (gives you a real `.app`)

```bash
cd app
open OpenVerb.xcodeproj
```

In Xcode: select the `OpenVerb` scheme, set the active scheme to **Release**, then **Product → Archive**. Once the archive is built, **Distribute App → Copy App** to get an `.app` bundle in a folder of your choice.

Or from the command line:

```bash
xcodebuild \
  -project app/OpenVerb.xcodeproj \
  -scheme OpenVerb \
  -configuration Release \
  -derivedDataPath build \
  build

# The bundle ends up here:
open build/Build/Products/Release/OpenVerb.app
```

## 5. Signing — what to expect

OpenVerb is configured for **ad-hoc signing** (`CODE_SIGN_IDENTITY = "-"`). This is intentional: the app is open source, there's no Apple Developer Program membership behind it, and I'd rather you trust your own build than a binary I uploaded.

The trade-off: macOS pins TCC permissions (Microphone, Accessibility, Input Monitoring) to the **code signature hash**. Every time you rebuild from scratch, the hash changes, and you have to re-grant permissions.

You have three choices.

### Choice 1 — Live with it (simplest)

Build once, grant permissions once, don't rebuild unless you have to. This is fine for daily use.

If permissions stop working after a rebuild:

```
System Settings → Privacy & Security → Microphone / Accessibility / Input Monitoring
  → remove the old OpenVerb entry
  → re-add the new one (or just re-launch the app and accept the prompt)
```

### Choice 2 — Personal stable identity (recommended, no Apple Dev needed)

A free, self-signed code-signing certificate gives you a stable identity, so macOS keeps your TCC grants across rebuilds. **No Apple Developer account, no sudo, two commands:**

```bash
./scripts/setup-signing-identity.sh   # one-time: creates "OpenVerb Dev" cert in login keychain
./scripts/sign-build.sh               # build a Release .app signed with that identity
```

The first script generates an RSA key + X.509 cert with the `codeSigning` extended key usage, bundles it as PKCS#12, and imports it into your login keychain. It also whitelists `/usr/bin/codesign` so the OS doesn't pop a permission dialog every build. None of this touches `project.pbxproj`.

The second script wraps `xcodebuild` with `CODE_SIGN_IDENTITY="OpenVerb Dev" CODE_SIGN_STYLE=Manual` and emits an `OpenVerb.app` under `build/Build/Products/Release/`.

Custom name? `./scripts/setup-signing-identity.sh "My Cert"` then `SIGN_IDENTITY="My Cert" ./scripts/sign-build.sh`.

After the first build: grant Microphone, Accessibility, and Input Monitoring once. Every rebuild after that inherits those grants automatically — that's the whole point.

### Choice 3 — Apple Developer ID (if you have one)

If you have a paid Developer ID, sign and notarize for distribution:

```bash
xcodebuild ... CODE_SIGN_IDENTITY="Developer ID Application: <Your Name>"
xcrun notarytool submit OpenVerb.app.zip --apple-id ... --wait
xcrun stapler staple OpenVerb.app
```

Again — local change, don't commit it.

## 6. First-launch on someone else's Mac

If you ship a `.app` to a friend, they'll need to:

1. Move `OpenVerb.app` to `/Applications`.
2. Strip the quarantine attribute that Safari/Telegram/etc. add to downloaded files:
   ```bash
   xattr -dr com.apple.quarantine /Applications/OpenVerb.app
   ```
3. Right-click the app and choose **Open** the first time. macOS will say "developer cannot be verified" — click **Open** anyway.
4. Grant Microphone, Accessibility, and Input Monitoring when prompted.

This is the standard "unsigned macOS app" dance. There's no way to avoid it short of a paid Developer ID.

## 7. Troubleshooting

**`cmake: command not found`**
`brew install cmake`.

**`swift build` fails with `error: no such module 'XYZ'`**
You're probably on the wrong Xcode toolchain. `xcode-select -p` should print `/Applications/Xcode.app/Contents/Developer`. If not: `sudo xcode-select -s /Applications/Xcode.app`.

**Engine builds but app says `engine subprocess exited with code 1`**
Check `~/Library/Logs/OpenVerb/engine.log`. The most common cause is missing model weights — re-run `scripts/download-model.sh`.

**Hotkey does nothing**
Accessibility permission isn't granted. Quit the app, remove it from Privacy & Security → Accessibility, relaunch.

**App launches, then immediately quits**
Probably a code-signing or entitlements mismatch after a partial rebuild. `rm -rf app/.build app/build` and rebuild from scratch.

**Permissions reset after every rebuild**
That's the ad-hoc signing trade-off. See "Choice 2" above.

## 8. Running the test suite

```bash
cd app && swift test                    # Swift unit + integration tests
./scripts/ov_smoke.sh                   # full app + engine via fixture audio
./scripts/ov_bench.py                   # latency / throughput benchmark
```

Tests run with mocked audio fixtures, so you don't need a real mic.
