# Wavetty — Developer & AI Agent Guide

This document is a working guide for anyone (humans or AI agents) extending
Wavetty, a fork of [Ghostty](https://github.com/ghostty-org/ghostty) maintained
at [withwave/wavetty](https://github.com/withwave/wavetty).

Read this **before** writing code, and re-read it any time upstream rebases
land. The release pipeline encodes the conventions described here; breaking
them silently breaks rebases or releases.

---

## 1. What Wavetty is

A standalone macOS terminal that ships from `withwave/wavetty:main`. The Zig
terminal engine and Linux GTK app are inherited verbatim from upstream; only
the macOS app is rebranded and extended.

- **App name**: Wavetty
- **Bundle ID**: `com.modincompany.wavetty` (upstream uses `com.mitchellh.ghostty`)
- **Executable**: `Contents/MacOS/wavetty` (lowercase; upstream is `ghostty`)
- **Data dir**: `~/Library/Application Support/com.modincompany.wavetty/`
- **Icon**: Wave design at `scripts/icon.icns` + `scripts/imageset_icons/*.png`
- **Code signing**: Developer ID Application: MODIN COMPANY (Team `8AC9KUZJ5P`)
- **Auto-update**: Sparkle is disabled. Custom GitHub Releases checker (see §4).

Wavetty and Ghostty can coexist on the same machine: separate bundle IDs,
separate data dirs, separate UserDefaults domains.

---

## 2. Core architecture

```
┌──────────────────────────────────────────────┐
│  macOS Swift App  (macos/Sources/)           │  AppKit + SwiftUI
│   • TerminalController, SurfaceView          │  → upstream
│   • AppDelegate, MainMenu                    │  → upstream
│   • Hosts/, Update/WavettyUpdateChecker      │  ← Wavetty additions
└──────────────┬───────────────────────────────┘
               │ C ABI (include/ghostty.h, module.modulemap)
               ▼
┌──────────────────────────────────────────────┐
│  libghostty (src/main_c.zig → libghostty.dylib) │  Zig
│   • Terminal state, escape parser            │
│   • Config parsing, input handling, PTY      │
│   • Kitty graphics + keyboard + text sizing  │
└──────────────────────────────────────────────┘
```

Swift can call libghostty functions (e.g. `ghostty_surface_text`,
`ghostty_app_new`) via `GhosttyKit` module. Wavetty additions in Swift never
modify the Zig core — that would invalidate rebases.

---

## 3. The Golden Rule: Rebase Safety

**Wavetty must never break `git rebase upstream/main`.** Upstream Ghostty is
actively developed; if our patches conflict frequently we lose the maintenance
budget.

Conventions, ordered from strongest to weakest:

### 3.1 Add new files in new directories (zero conflict)

Anything Wavetty-only lives in a new subdirectory of `macos/Sources/Features/`:

| Feature | Location |
|---|---|
| GitHub Release update checker | `macos/Sources/Features/Update/WavettyUpdateChecker.swift` |
| SSH host management | `macos/Sources/Features/Hosts/` (SSHHostStore, SSHConfigParser, SSHURIParser, SSHHostMetadata, SSHHostManagerView, SSHMenuController, SSHProcessInspector, SSHKeychain, SSHAskpass) |
| Recent-window session recovery | `macos/Sources/Features/Sessions/SessionHistoryStore.swift` |

**Session recovery** (`SessionHistoryStore`): snapshots open terminal windows
(tabs + split tree + frame) on a 15s timer, on window close, on resign-key, and
at termination — so a closed window or a force-killed app can be reopened from
the Dock menu with its layout and position restored. Entries are deduped by a
frame-independent content signature and capped to 16 (LRU). SSH leaves are
detected live (foreground process via `ghostty_surface_pwd`/`KERN_PROCARGS2`) so
they reconnect on restore. Persisted to `recent-windows.json`. Observes
`NSWindow.willCloseNotification` etc. globally — **no upstream file edits**.

**SSH auto-detect + Keychain passwords**: `SSHProcessInspector` reads a surface's
foreground argv via `sysctl(KERN_PROCARGS2)`; a plain `ssh user@host` typed in
the terminal is auto-added to `~/.ssh/config` and tracked. `SSHKeychain` stores
per-host passwords in the login Keychain (via the `security` CLI); `SSHAskpass`
writes a helper script and sets `SSH_ASKPASS`/`SSH_ASKPASS_REQUIRE=force` on
connect so ssh auto-fills the stored password.

**SSH discoverability**: a code-built top-level **SSH** menu (`SSHMenuController`,
no xib edit) and an **SSH Hosts** section in the Dock menu list pinned/recent
hosts for one-click connect, plus "Manage Hosts… ⌘⇧K".

Xcode auto-discovers files via `PBXFileSystemSynchronizedRootGroup`, so no
`project.pbxproj` edits are required.

### 3.2 Minimize edits to upstream files

When you must touch an upstream Swift file (Command Palette integration, etc.):
- Add **one** new method, **one** new property, or **one** new call site.
- Mark the edit with a `// Wavetty:` comment explaining why.
- Keep the diff to <10 lines per file.

Current Wavetty edits in upstream files:

| File | Wavetty change |
|---|---|
| `Sources/App/macOS/AppDelegate.swift` | `WavettyUpdateChecker.checkOnLaunch()` call; launch warmups (`SessionHistoryStore`, `SSHMenuController.install()`); `reloadDockMenu()` builds Recent Windows + SSH Hosts sections; `checkForUpdates(_:)` IBAction redirects; string rewrites ("Quit Ghostty?" → "Quit Wavetty?") |
| `Sources/Features/Command Palette/CommandPalette.swift` | Added optional `dynamicOptions:` parameter to `CommandPaletteView`; moved `hoveredOptionID` into `CommandTable` so hover during scroll doesn't re-evaluate the whole palette body (fixes severe scroll/click lag) |
| `Sources/Features/Command Palette/TerminalCommandPalette.swift` | `sshDynamicOptions(query:)` method + one call site |
| `Sources/Features/Terminal/BaseTerminalController.swift` | `lastComputedTitle` default `🌊`, fallback `titleDidChange(to: "🌊")`, bell prefix moved to suffix |
| `Sources/Features/Terminal/Window Styles/TitlebarTabs{Tahoe,Ventura}TerminalWindow.swift` | default title `"🌊 Wavetty"` |
| `Sources/Ghostty/Surface View/SurfaceView_AppKit.swift` | `self.title = "🌊"` fallback |
| `Sources/Ghostty/Surface View/SurfaceView_UIKit.swift` | initial title `"🌊"` |
| `Sources/Features/Terminal/Window Styles/*.xib` + `Sources/Features/QuickTerminal/QuickTerminal.xib` | `👻 Ghostty` → `🌊 Wavetty` in default window title |
| `Sources/Features/Settings/SettingsView.swift` | unchanged (upstream placeholder) |

Many remaining "Ghostty" strings (NSAlert text, etc.) are patched
**post-build** by `scripts/build-wavetty.sh` so the source files stay clean.
See §5.

### 3.3 Never modify the Zig core

Anything in `src/` is upstream. The C ABI in `include/ghostty.h` is upstream.
The macOS bridge (`macos/Sources/Ghostty/Ghostty.*.swift`) is upstream — touch
only when absolutely necessary, and only with a tiny diff.

### 3.4 Never modify `project.pbxproj` or `build.zig`

Xcode synchronized groups auto-pick up new Swift files. Adding a file does NOT
require pbxproj changes. If you find yourself needing to edit pbxproj, you're
probably doing something wrong.

---

## 4. Features

### 4.1 Rebrand (entirely post-build via `scripts/build-wavetty.sh`)

The script `scripts/build-wavetty.sh` runs `zig build` then:

1. Renames `Ghostty.app` → `Wavetty.app`
2. Renames `Contents/MacOS/ghostty` → `Contents/MacOS/wavetty` and updates
   `CFBundleExecutable`
3. Rewrites `Info.plist` via `plutil`:
   - `CFBundleName`/`DisplayName` → Wavetty
   - `CFBundleIdentifier` → `com.modincompany.wavetty`
   - `CFBundleShortVersionString`/`CFBundleVersion` ← `VERSION` file
   - `CFBundleIconFile` → Wavetty
   - `OSAScriptingDefinition` → `Wavetty.sdef`
   - Removes `SUPublicEDKey`, sets `SUEnableAutomaticChecks = false`
4. Sed-patches Info.plist (XML) for NSUsageDescription strings, Finder Quick
   Actions ("New Wavetty Tab Here"), UTI description ("Wavetty Surface
   Identifier")
5. Replaces `Ghostty.icns` with `scripts/icon.icns` (renamed to `Wavetty.icns`)
6. Renames `Ghostty.sdef` → `Wavetty.sdef`
7. Sed-patches compiled `.nib` files for menu strings ("About Ghostty" →
   "About Wavetty", etc.) — same-length-only, preserves binary layout
8. Sed-patches `👻 Ghostty` → `🌊 Wavetty` in `.nib` window titles
9. Replaces `Assets.xcassets/AppIconImage.imageset/*.png` with
   `scripts/imageset_icons/*.png` BEFORE build (so Assets.car compiles with
   our icon)
10. Signs with Developer ID, hardened runtime, timestamp
11. `--dmg`: builds DMG with `/Applications` symlink for drag-install,
    submits to Apple Notary, staples
12. `--release`: uploads DMG to existing GitHub Release

Source files patched in-place during build (and restored on exit via `trap`):
- `macos/Sources/Features/Terminal/BaseTerminalController.swift` (adds
  document icon button image override — could move to source permanently)
- `macos/Sources/Features/About/AboutView.swift` (Text("Ghostty") →
  `Bundle.main.CFBundleName`)
- `macos/Assets.xcassets/AppIconImage.imageset/*.png` (overlaid with our PNGs)

### 4.2 Auto-update via GitHub Releases (`WavettyUpdateChecker`)

File: `macos/Sources/Features/Update/WavettyUpdateChecker.swift`

- Polls `GET https://api.github.com/repos/withwave/wavetty/releases/latest`
- Compares `tag_name` (stripping `v` prefix and `-withwave` suffix for the
  semver portion) against `CFBundleShortVersionString`
- `checkOnLaunch()`: silent check on app start, throttled to once per 24h via
  `WavettyLastUpdateCheck` UserDefault. Only shows UI if update available.
- `checkManually()`: triggered from menu "Check for Updates...", always shows
  result (up-to-date or available or error).
- "Skip This Version" stores tag in `WavettySkippedVersion` UserDefault so
  silent checks don't re-pester. Manual check ignores the skip.

Integration points (AppDelegate.swift):
- `applicationDidFinishLaunching` → `WavettyUpdateChecker.checkOnLaunch()`
- `@IBAction func checkForUpdates(_:)` → `WavettyUpdateChecker.checkManually()`

### 4.3 SSH host management

Files in `macos/Sources/Features/Hosts/`:

| File | Role |
|---|---|
| `SSHURIParser.swift` | Parses `user@host:port` shorthand, IPv6 brackets, `as <alias>` suffix |
| `SSHConfigParser.swift` | Reads `~/.ssh/config` (Host/HostName/User/Port/IdentityFile/ProxyJump); appends new Host blocks; removes blocks safely |
| `SSHHostMetadata.swift` | Sidecar JSON store at `~/Library/Application Support/<bundleID>/hosts-metadata.json` — pinned/group/tags/note/useCount/lastConnected/autoAdded |
| `SSHHostStore.swift` | `@MainActor ObservableObject` combining config + metadata; suggestions(scoring), addFromURI, connect (via `Ghostty.SurfaceConfiguration.command`), recordConnection |
| `SSHHostManagerView.swift` | SwiftUI NavigationSplitView window — sidebar with grouped list (Ungrouped/<groups>/Auto-added), detail pane with Connection (read-only) + Wavetty Metadata (editable) + Statistics + Connect/Delete |

Command Palette integration (the only edit to upstream palette code):
- Typing `ssh` activates `sshDynamicOptions(query:)` provider
- `ssh <body>` matches existing hosts by alias/hostname (fuzzy scored)
- `ssh <user@host:port>` shows "SSH: Add & Connect" emphasized item that
  appends to `~/.ssh/config` and opens a new tab
- Always-present "SSH: Manage Hosts…" item opens the manager window

`~/.ssh/config` is the **single source of truth**. Wavetty:
- Reads it on every store reload
- Appends new blocks with `# Added by Wavetty <iso8601>` header
- Removes blocks only when user clicks Delete (with confirmation alert);
  preserves the rest of the file
- Never modifies existing user-curated blocks (hostname/user/port edits in
  the UI are deferred — would require diff-and-replace, risk corrupting
  formatting)

Connection mechanism: `Ghostty.SurfaceConfiguration.command = "ssh \(alias)"`
+ `waitAfterCommand = true`. Ghostty exec's ssh directly as the surface
process — no shell-injection timing race.

---

## 5. Build / Release

### 5.1 Prerequisites (one-time)

- Apple Developer Program subscription ($99/year), Team ID `8AC9KUZJ5P`
- Developer ID Application certificate in login keychain
- `xcrun notarytool` profile registered as `modin-notary`
- `brew install zig@0.15` (Zig 0.15.2 patched bottle — stock Zig 0.15 fails
  to link against Xcode 26.4 SDK)
- `xcodebuild -downloadComponent MetalToolchain` after Xcode updates
- `gh auth login` for GitHub CLI

Detailed cert/keychain steps are in `RELEASING-WITHWAVE.md`.

### 5.2 Daily commands

```bash
# Build (no DMG)
./scripts/build-wavetty.sh

# Build + DMG + notarize (output: zig-out/Wavetty.dmg)
./scripts/build-wavetty.sh --dmg

# Build + DMG + notarize + upload to existing GitHub release
./scripts/build-wavetty.sh --release
```

### 5.3 Full release pipeline

`scripts/release-wavetty.sh` orchestrates rebase → version bump → build →
notarize → release create/update → tag → push:

```bash
# Re-release same version (after code changes only)
./scripts/release-wavetty.sh

# Bump version + new release
./scripts/release-wavetty.sh --bump 1.3.4-withwave

# After resolving rebase conflicts manually
./scripts/release-wavetty.sh --skip-rebase
```

The script uses `--force-with-lease` on push because rebasing on upstream/main
rewrites local commit hashes (history was already pushed before the rebase).

### 5.4 Cache clearing

Before any release build, `release-wavetty.sh` does NOT clear caches. If you
suspect stale state, run manually:

```bash
rm -rf ~/Library/Developer/Xcode/DerivedData/Ghostty-* \
       macos/build .zig-cache zig-out
```

Xcode incremental build can silently use cached object files even after
source changes. When Swift edits don't seem to take effect, the cache is
the first place to check.

---

## 6. Known gotchas (we learned the hard way)

### 6.1 macOS `sed` and 4-byte UTF-8 emoji

```bash
# Often fails silently in non-C locale:
sed -i '' 's/👻/🌊/g' file.xib

# Use Python instead:
python3 -c "
import sys
p = sys.argv[1]
with open(p,'r',encoding='utf-8') as f: s = f.read()
open(p,'w',encoding='utf-8').write(s.replace('👻', '🌊'))
" file.xib
```

`LC_ALL=C sed` works for same-byte-length replacements (e.g. "Ghostty" ↔
"Wavetty", both 7 chars) but is fragile for multi-byte chars.

### 6.2 `xxd | grep` splits across lines

```bash
# WRONG — emoji bytes can straddle xxd line boundary:
xxd file | grep -c "f09f 8c8a"

# RIGHT — collapse to single line first:
xxd -p file | tr -d '\n' | grep -oc f09f8c8a
```

### 6.3 Xcode DerivedData persists across builds

Even after `rm -rf macos/build .zig-cache`, Xcode's
`~/Library/Developer/Xcode/DerivedData/Ghostty-*` can keep stale Swift
objects. If a code change doesn't appear in the binary, nuke DerivedData.

### 6.4 SwiftUI on macOS < 14

We target macOS 13+. Avoid `ContentUnavailableView` and other macOS 14-only
SwiftUI APIs unless guarded with `@available`.

### 6.5 NSAlert blocks but window count = 0

The update-available alert shows as a separate NSWindow but `count of windows`
in AppleScript may not see it immediately. For UI tests, prefer querying
window titles or use `osascript` accessibility paths.

### 6.6 AppleScript keystrokes are racy with focus

`keystroke "p" using {command down, shift down}` to open Command Palette
followed immediately by `keystroke "ssh"` often types into the wrong app
because focus hadn't transferred yet. Add `delay 1` between keystrokes, or
use `tell application process "wavetty"` to scope. Even then, multi-monitor
setups are flaky — prefer accessibility actions over keystrokes when
possible.

### 6.7 Force push after rebase

`./scripts/release-wavetty.sh` rebases on `upstream/main`, which rewrites all
local commit hashes. The subsequent push to origin/main is not fast-forward
and requires `--force-with-lease`. The script handles this automatically.

### 6.8 `ssh_config` permissions

`~/.ssh/` should be `0700`, `~/.ssh/config` `0600`. Our parser/writer
preserves these on existing files and sets them when creating from scratch.

---

## 7. Conventions

### 7.1 Commit messages

- Conventional commits style: `feat(wavetty): ...`, `fix(wavetty): ...`,
  `chore: ...`, `docs: ...`
- `feat(wavetty):` and `fix(wavetty):` for Wavetty-specific changes
- Plain `feat:` / `fix:` only for changes we'd merge upstream
- Always end with `Co-Authored-By: <model>` line if AI-assisted

### 7.2 User-facing language

- macOS UI labels: English (consistent with macOS conventions and to match
  the rest of Ghostty)
- Documentation files (RELEASING-WITHWAVE.md, this file): Korean is fine —
  primary maintainer is Korean
- Commit messages: English

### 7.3 Swift style

- Default to no comments. Only add when WHY is non-obvious.
- Use `// Wavetty:` comment prefix for any patch in upstream files
- Prefer `@MainActor` for UI types, `ObservableObject` (not `@Observable`)
  since we still support macOS 13

### 7.4 File naming

- Wavetty-specific Swift files: prefix with `Wavetty` (e.g.
  `WavettyUpdateChecker.swift`) OR use a feature-specific name in a new
  feature directory (e.g. `Hosts/SSHHostStore.swift`)

---

## 8. Project state snapshot

As of the latest commit:

- **Version**: see `VERSION` file
- **Bundle ID**: `com.modincompany.wavetty`
- **Latest release**: see `gh release view --repo withwave/wavetty`
- **Active features**: rebrand, custom icon, GitHub Release update checker,
  SSH host management (palette + manager window), end-to-end release script

### Files unique to Wavetty

```
VERSION                                          # version string
WAVETTY.md                                       # this file
RELEASING-WITHWAVE.md                            # release/signing setup guide
scripts/build-wavetty.sh                         # build + sign + notarize
scripts/release-wavetty.sh                       # full release pipeline
scripts/icon.icns                                # Wave icon source
scripts/imageset_icons/*.png                     # AppIconImage.imageset PNGs

macos/Sources/Features/Update/
    WavettyUpdateChecker.swift                   # GitHub Releases polling

macos/Sources/Features/Hosts/
    SSHURIParser.swift
    SSHConfigParser.swift
    SSHHostMetadata.swift
    SSHHostStore.swift
    SSHHostManagerView.swift
```

### Files modified in upstream (kept small)

```
macos/Sources/App/macOS/AppDelegate.swift                          (~6 lines)
macos/Sources/Features/Command Palette/CommandPalette.swift        (~10 lines)
macos/Sources/Features/Command Palette/TerminalCommandPalette.swift (~55 lines)
macos/Sources/Features/Terminal/BaseTerminalController.swift       (~3 lines)
macos/Sources/Features/Terminal/Window Styles/Titlebar*.swift       (1 line each)
macos/Sources/Features/Terminal/Window Styles/*.xib                 (1 string each)
macos/Sources/Features/QuickTerminal/QuickTerminal.xib              (1 string)
macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift        (~3 lines)
macos/Sources/Ghostty/Surface View/SurfaceView_UIKit.swift          (1 line)
macos/Sources/Features/App Intents/*.swift                          (small)
macos/Sources/Features/Update/UpdatePopoverView.swift               (1 line)
macos/Sources/Features/Command Palette/TerminalCommandPalette.swift (small)
```

---

## 9. What to do when upstream rebases conflict

1. `./scripts/release-wavetty.sh` will abort at the rebase step. It tells you
   to resolve manually.
2. `git rebase --continue` after fixing each conflict.
3. Re-run `./scripts/release-wavetty.sh --skip-rebase` to finish.

When conflicts hit upstream files we've patched (e.g. AppDelegate.swift,
xib files), prefer to **keep our Wavetty edit and re-apply over the new
upstream code**. Each Wavetty edit is small and stand-alone.

---

## 10. Things that are explicitly NOT done

- **Sparkle EdDSA signing key + appcast.xml**: too much overhead vs. the
  current "open GitHub Releases page" UX. The bones are there (UpdatePopoverView
  references "Wavetty can automatically check…") but the actual signing
  infrastructure isn't wired up.
- **Windows support**: Ghostty itself doesn't target Windows. See README in
  upstream.
- **In-UI ssh_config editing**: Editing host blocks risks corrupting the
  user's hand-written formatting. We only append/remove.
- **Keychain integration for SSH passphrases**: Future work.
- **iCloud sync of hosts-metadata.json**: Future work.

---

## 11. Quick orientation for a new AI agent

Read order for first session:
1. This file (WAVETTY.md) — 5 min
2. `RELEASING-WITHWAVE.md` — release pipeline detail
3. `scripts/build-wavetty.sh` — the post-build rebranding logic
4. `macos/Sources/Features/Hosts/SSHHostStore.swift` — example of a
   well-isolated feature
5. `macos/Sources/Features/Update/WavettyUpdateChecker.swift` — minimal
   pattern for a Wavetty-specific service

When asked to add a new feature, default to:
1. Create a new directory under `macos/Sources/Features/<FeatureName>/`
2. Add at most one tiny patch to an upstream file to wire it up (usually
   a Command Palette item, AppDelegate call, or menu action)
3. Test with `./scripts/build-wavetty.sh`
4. Commit with `feat(wavetty): <summary>`
5. Only release when the user asks
