# ADE

A native macOS terminal multiplexer and coding-agent manager (name TBD).
Sessions live in a background daemon, so closing the app, a crash, or a
reboot never loses them: Claude Code and Codex sessions come back with
`--resume` and pick up the same conversation.

See [SPEC.md](SPEC.md) for the product spec, [DECISIONS.md](DECISIONS.md)
for choices made along the way, and [PROGRESS.md](PROGRESS.md) for status.

## Architecture in one picture

```
ADE.app (Swift, AppKit + SwiftUI)
  ├─ each pane = libghostty surface running `ade attach <session>`
  └─ control connection (NDJSON) ──▶ ade daemon (Rust, launchd agent)
                                        ├─ SQLite catalog: workspaces, projects, tabs, sessions, agents, settings
                                        ├─ hooks + OSC 7501 → activity, notifications
                                        └─ spawns one `ade holder` per session (PTY + headless VT)
                                             └─ survives daemon restarts; restored after reboot
```

## Build

Requirements: macOS 14+, Xcode (with the Metal toolchain:
`xcodebuild -downloadComponent MetalToolchain`), Rust stable, Zig 0.17 (only to
build libghostty).

```sh
# 1. libghostty (once; ~2 min). Produces vendor/GhosttyKit.xcframework
git clone --depth 1 https://github.com/ghostty-org/ghostty.git vendor/ghostty
(cd vendor/ghostty && zig build -Demit-xcframework=true -Dxcframework-target=native \
    -Demit-macos-app=false -Demit-docs=false -Doptimize=ReleaseFast)
mv vendor/ghostty/macos/GhosttyKit.xcframework vendor/

# 2. App bundle (Rust core + Swift app) → build/ADE.app
tools/build-app.sh            # release
tools/build-app.sh debug      # faster, debug

# Tests (Rust core: unit + 17 end-to-end tests over real PTYs)
(cd core && cargo test)
```

## Run

```sh
open build/ADE.app
```

On first launch the app installs a launchd agent `dev.ade-dev.daemon` pointing
at the `ade` binary inside the bundle and starts it. Data lives in
`~/Library/Application Support/ade-dev/` (SQLite, sockets, logs, terminal
config). macOS will ask for notification permission.

Useful commands (the CLI is at `build/ADE.app/Contents/Resources/bin/ade`):

```sh
ade status                       # is the daemon running?
ade ctl state.get                # whole catalog as JSON
ade ctl session.screen_text '{"id":"<session>"}'
ade attach <session>             # attach any terminal to a session
```

### Development mode

```sh
export ADE_HOME=/tmp/ade-dev     # isolated data dir (no launchd agent is installed)
ADE_DEBUG=1 build/ADE.app/Contents/MacOS/ADE
tools/dbg ui_state               # app state as JSON
tools/dbg ui_action '{"name":"new_terminal"}'
tools/dbg screenshot '{"path":"/tmp/shot.png"}'   # self-capture, no Screen Recording permission needed
```

## Clean up / uninstall

```sh
build/ADE.app/Contents/Resources/bin/ade uninstall-agent   # removes ~/Library/LaunchAgents/dev.ade-dev.daemon.plist
pkill -f 'ADE.app/Contents/Resources/bin/ade'               # stops the daemon and all session holders
rm -rf ~/Library/Application\ Support/ade-dev               # all ADE data
defaults delete dev.ade-dev.app 2>/dev/null                 # UI selection state
```

## Keyboard

| | |
|---|---|
| ⌘T / ⌘⇧T | New terminal tab / new tab with the first pinned agent |
| ⌘D / ⌘⇧D | Split right / down |
| ⌘W | Close pane |
| ⌘⌥ arrows | Move focus between panes |
| ⌘1…⌘9, ⌘⇧[ ⌘⇧] | Tabs |
| ⌃1…⌃9, ⌃⌘← ⌃⌘→, two-finger swipe on the sidebar | Workspaces |
| ⌘⇧U | Jump to the next session waiting for input |
| ⌘. | Stop session |
| ⌘B, ⌘O, ⌘⇧O, ⌘, | Sidebar, open project in default app, add project, settings |

## Known gaps (MVP)

- Scrollback replayed on attach is capped at 3000 lines per session (the daemon keeps 5000).
- Plain terminal sessions are restored after a reboot as a fresh shell in the
  same directory (by design, SPEC §4); only agents resume.
- Notifications are posted by the app; while the app is fully quit, sessions
  keep running but no notifications are shown.
- Not yet built: git worktrees, dock + Actions, right-hand Changes/History/Files
  panel, usage limits in the bottom bar, remote hosts, chat view, command
  palette, custom key bindings. Feature flags for these exist in Settings.
- Codex resume relies on finding the rollout file for the session's folder;
  verified only with fake data, not a live Codex run.

## Morning manual test list

Things automation could not verify (no physical keyboard/trackpad, no
permission dialogs):

1. **Open** `build/ADE.app`, accept the notification prompt.
2. **Real typing**: type in a terminal, including Turkish characters with your
   keyboard layout, ⌥ combinations, and an IME if you use one.
3. **Trackpad**: two-finger swipe left/right over the sidebar switches workspaces.
4. **Mouse**: select text and ⌘C, scroll back, click links (⌘-click).
5. **Your agents**: Settings → Agents → edit `claude`, and add `Claude (work)` with
   Command `/Users/anilsenay/.local/bin/claude-work-profile/claude` (or
   `claude-work` with "Run through my login shell"). Pin it to get a one-click button.
6. **Notification click**: start a Claude task, switch to another app; when the
   notification arrives, click it → ADE should focus that pane.
7. **Quit ADE (⌘Q) while Claude works**, reopen: the session is still running.
8. **Reboot** (or log out/in) with a Claude session open: after login, opening
   ADE shows the session resumed with the conversation intact.
9. Settings → Appearance → *Import from Ghostty*, Apply; check fonts/theme.
