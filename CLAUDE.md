# OpenVerb — Agent Notes

## 🚨 DO NOT TOUCH: Code Signing Configuration 🚨

**File:** `app/OpenVerb.xcodeproj/project.pbxproj`
**Settings:** `CODE_SIGN_IDENTITY`, `CODE_SIGN_STYLE`, `DEVELOPMENT_TEAM`, `CODE_SIGN_ENTITLEMENTS`

The current values are **intentional** and have been fixed by the human owner multiple
times already:

```
CODE_SIGN_IDENTITY = "-";
CODE_SIGN_STYLE = Automatic;
DEVELOPMENT_TEAM = G568D6B8S9;
CODE_SIGN_ENTITLEMENTS = OpenVerb/Resources/OpenVerb.entitlements;
```

**DO NOT** "fix" or "improve" these values, even if:

- `"-"` looks like ad-hoc (it is, by design — dev builds only)
- The team ID `G568D6B8S9` doesn't match any cert in the current Keychain
- You think switching to `"Apple Development"` would be better for TCC persistence
- You see a build warning about signing
- Another agent's suggestion says otherwise

Yes, ad-hoc signing means macOS TCC grants reset on every rebuild. The human
owner is aware and accepts this trade-off for local dev. A proper fix requires
manual action (creating a stable signing identity, configuring via Xcode GUI) —
do NOT attempt it via pbxproj edits from an automation context.

If the user explicitly asks to change signing — only then proceed, and confirm
every change before applying.

---

## Build commands

- SPM build/test: `cd app && swift build` / `swift test --filter <FilterName>`
- Xcode build: use `ov` shell function (wraps `xcodebuild -project app/OpenVerb.xcodeproj -scheme OpenVerb -configuration Debug build`)

## Bug tracker

- `bugs.md` at repo root — numbered bug list with status markers.
- Negative tests for confirmed bugs live in `app/OpenVerbTests/OpenBugsNegativeTests.swift`.

## Commit style

- No `Co-Authored-By`, no AI attribution
- Short, lowercase, no conventional commit prefixes (no `feat:`, `fix:`, `chore:`)
- One logical change per commit
