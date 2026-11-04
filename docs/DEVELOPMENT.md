# Developing Octomux

## Layout

| Path | What |
|---|---|
| `app/` | The macOS app: Swift, AppKit + SwiftUI (SwiftPM package). Terminals are libghostty surfaces. |
| `core/` | Rust workspace: the `octomux` binary (daemon, holder, CLI) and `octomux-proto` (wire protocol). |
| `app/editor-web/` | The code viewer (CodeMirror 6), bundled into `app/Resources/editor/` with `bun run build`. |
| `tools/` | Build, release and test scripts, the debug client `dbg`, the UI fixture. |
| `docs/` | User guide, this file, the design system (`DESIGN.md`), README images. |

## Requirements

- macOS 14+, Apple Silicon
- Xcode, with the Metal toolchain: `xcodebuild -downloadComponent MetalToolchain`
- Rust stable
- Zig 0.17 (only to build libghostty)

## Build

```sh
tools/build-ghostty.sh          # libghostty at the pinned commit → vendor/GhosttyKit.xcframework (once)
tools/build-app.sh              # release → build/Octomux.app
tools/build-app.sh debug        # faster
```

`build-app.sh` builds the Rust core, the Swift app, and assembles the bundle: the `octomux` CLI in
`Contents/Resources/bin`, Sparkle in `Contents/Frameworks`, the editor bundle and Ghostty's terminal themes.
Local builds are ad-hoc signed and don't check for updates.

## Test

```sh
(cd core && cargo test)          # unit tests + end-to-end tests over real PTYs
(cd app && swift test)           # app logic: palette, shortcuts, worktrees, chat parsing, usage
```

## Run against a throwaway data folder

The installed app uses `~/Library/Application Support/Octomux` and a launchd agent. For development, point
everything at another folder; then no launchd agent is installed and your real sessions are untouched:

```sh
export OCTOMUX_HOME=/tmp/octomux-dev
OCTOMUX_DEBUG=1 build/Octomux.app/Contents/MacOS/Octomux
tools/dbg ui_state                                  # app state as JSON
tools/dbg ui_action '{"name":"new_terminal"}'
tools/dbg screenshot '{"path":"/tmp/shot.png"}'     # self-capture, no Screen Recording permission needed
```

`tools/dbg` talks to the app's debug socket (`$OCTOMUX_HOME/run/app-debug.sock`, only with `OCTOMUX_DEBUG=1`).
Other variables: `OCTOMUX_BIN` (the CLI the app runs), `OCTOMUX_SESSION_ID` (set inside sessions),
`OCTOMUX_NO_USAGE_PROBE` (skip the Claude usage probe).

### UI fixture

Fake agents in working / input / done states, git projects, usage readings, a dock action:

```sh
tools/ui-fixture.sh             # builds OCTOMUX_HOME=/tmp/octomuxU
tools/ui-restart.sh             # (re)starts the debug app against it; W=900 H=640 for a small window
OCTOMUX_HOME=/tmp/octomuxU tools/dbg ui_action '{"name":"palette","value":"split"}'
OCTOMUX_HOME=/tmp/octomuxU tools/dbg update_toast '{"show":"available"}'
```

## Release

Needs the maintainer's Developer ID certificate, the `octomux-notary` notarytool profile and the Sparkle EdDSA
private key in the login keychain.

```sh
echo 0.2.0 > VERSION && git commit -am "Release 0.2.0"
tools/release.sh
```

`release.sh` builds, signs inside out with the hardened runtime (CLI, Sparkle's helpers, the app), notarizes
and staples the app and the DMG, and writes `dist/Octomux-<v>.dmg`, `dist/Octomux-<v>.zip` and
`dist/updates/appcast.xml` (EdDSA-signed by Sparkle's `generate_appcast`). Public settings (feed URL, download
prefix, EdDSA public key) are in `release.env`. The build number is the commit count, so it only grows.

### Updates

Sparkle 2 drives updates with our own UI (`Core/Updater.swift`, the toast). After an update the app restarts
the daemon into the new binary (`hello` reports `stale`); session holders keep running, so no session is lost.
Opened from the disk image or Downloads, the app offers to move itself to /Applications first.
