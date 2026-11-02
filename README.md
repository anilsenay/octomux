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

State after the overnight build: the launchd agent `dev.ade-dev.daemon` is installed
and running from `build/ADE.app`; the data folder holds one workspace (Personal), the
`new-ade` project and your agent profiles — no sessions.

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

UI fixture (fake agents in working / input / done states, git projects, usage readings, a dock action),
never touching your real data:

```sh
tools/ui-fixture.sh              # builds ADE_HOME=/tmp/adeU
tools/ui-restart.sh              # (re)starts the debug app against it; W=900 H=640 for a small window
ADE_HOME=/tmp/adeU tools/dbg ui_action '{"name":"palette","value":"split"}'
ADE_HOME=/tmp/adeU tools/dbg render_view '{"view":"usage","dark":true,"path":"/tmp/u.png"}'
```

Note: `tools/build-app.sh` rebuilds `build/ADE.app`, which the installed launchd daemon runs from.
Use `release` for that bundle; for UI work run `app/.build/debug/ADE` (as `ui-restart.sh` does).

## Appearance

Three theme presets (Settings → Appearance or ⌘K "Theme"): **Ink** (default), **Grid**, **Glass**, each with
dark/light, plus System/Dark/Light mode. Terminal colors follow the theme (written to `$ADE_HOME/theme.conf`,
loaded after your `terminal.conf`); turn off "Use theme colors in the terminal" to use your own. Design
system: `DESIGN.md`. App icon: `swift tools/make-icon.swift` regenerates `app/Resources/AppIcon.icns`.

## Usage limits

Claude sessions started by ADE get a status line command (`ade statusline`, injected with `--settings`
like the hooks). It reports `rate_limits` (5-hour / weekly) to the daemon at most every 15 s and then runs
**your own** `statusLine` command from your settings with the same input, so your status line is unchanged.
(With no status line of your own it prints a short `model · context%` line.) Codex limits are read from its
rollout files once a minute while a Codex session runs. The status bar shows the focused agent's profile plus
profiles marked "Always show" (in the usage popover or the agent's settings).

## Chat view (Claude)

⌘⇧C (or the speech-bubble button in the top bar) shows a Claude session as a chat: its own transcript, live,
with tool calls as cards. What you type there goes into the same session, as if typed in the terminal.
Permission prompts and menus are answered in the terminal (the chat offers a one-click switch). Nothing else
runs: same process, same login. Turn it off in Settings → Features.

## Remote hosts

1. Build `ade` for the server: `rustup target add x86_64-unknown-linux-gnu && tools/build-linux.sh x86_64`
   (or `aarch64`; needs `zig`). Copy `core/target/<arch>-unknown-linux-gnu/release/ade` to the server, e.g.
   `~/.local/bin/ade`.
2. Settings → Hosts → Add host: SSH destination (`user@box` or a `Host` from `~/.ssh/config`; key/agent auth,
   no prompts) and the path of `ade` there. **Test**, then **Connect**. Or pick it in the workspace menu.
3. The daemon on the server starts on first use and keeps sessions running after you disconnect (no
   launchd there; run `ade daemon` under systemd if you want it to survive server reboots).

Custom command hosts take any prefix that reaches the other side, e.g. `docker exec -i <container>` (with
pane prefix `docker exec -it <container>`).

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
| ⌘K | Command palette (sessions, projects, commands, agents, settings, themes) |
| ⌘J, ⌘⌥B | Dock, Changes panel |

All menu shortcuts can be changed in Settings → Keyboard (click a shortcut, press the new keys; Delete
unbinds). Overrides are the global setting `keybindings`.

## Known gaps (MVP)

- Scrollback replayed on attach is capped at 3000 lines per session (the daemon keeps 5000).
- Plain terminal sessions are restored after a reboot as a fresh shell in the
  same directory (by design, SPEC §4); only agents resume.
- Notifications are posted by the app; while the app is fully quit, sessions
  keep running but no notifications are shown.
- See PROGRESS.md for what is built and what is still open.
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
5. **Your agents**: `claude` and **Claude (work)** (your `claude-work` alias) are already
   set up and pinned next to the + button. Start one of each and check the account in
   Claude's status line. Other installed CLIs (gemini, amp, kiro-cli, agy) can be added
   from Settings → Agents → "Installed on this Mac".
6. **Notification click**: start a Claude task, switch to another app; when the
   notification arrives, click it → ADE should focus that pane.
7. **Quit ADE (⌘Q) while Claude works**, reopen: the session is still running.
8. **Reboot** (or log out/in) with a Claude session open: after login, opening
   ADE shows the session resumed with the conversation intact.
9. Settings → Appearance → *Import from Ghostty*, Apply; check fonts/theme.
