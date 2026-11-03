# Notes for coding agents

Read this before changing Octomux. [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) has the full build and test guide.

## Never touch the user's real sessions

Octomux manages live terminals and agents. The installed app's daemon (`dev.octomux.daemon`, data in
`~/Library/Application Support/Octomux`) may be running the very session you are in.

- Always work against a throwaway data folder: `export OCTOMUX_HOME=/tmp/octomux-dev` (or the fixture,
  `tools/ui-fixture.sh` → `/tmp/octomuxU`). With `OCTOMUX_HOME` set, no launchd agent is installed or changed.
- `tools/dbg` reads `OCTOMUX_HOME`; without it, it talks to the real app.
- Never stop processes by a broad pattern (`pkill octomux`, `killall Octomux`). Stop exactly what you started:
  by PID, or with `OCTOMUX_HOME=<yours> octomux ctl daemon.stop_all`.
- `tools/build-app.sh` replaces `build/Octomux.app`, which a developer's installed daemon may run from. Prefer
  `swift build` + `app/.build/debug/Octomux` (as `tools/ui-restart.sh` does) for UI work.
- Don't edit the user's agent configuration (`~/.claude/settings.json`, `~/.codex/…`). Octomux passes its hooks
  with `--settings` for a reason.

## Build and check

```sh
(cd core && cargo build && cargo test)
(cd app && swift build && swift test)
tools/ui-fixture.sh && tools/ui-restart.sh          # then: OCTOMUX_HOME=/tmp/octomuxU tools/dbg screenshot '{"path":"/tmp/s.png"}'
```

Verify UI changes in the fixture with a screenshot, not only by compiling.

## Code

- `core/` (Rust): `octomux` is the daemon (`daemon/`), the per-session holder (`holder.rs`) and the CLI.
  The app talks to the daemon over NDJSON on `$OCTOMUX_HOME/run/daemon.sock`; methods are in `daemon/mod.rs`
  (`dispatch`). Holders survive daemon restarts; keep it that way.
- `app/` (Swift): `Core/` is state and services (`AppModel`, `DaemonClient`, `Updater`), `UI/` the views.
  Colors and metrics come from `T` (`UI/Theme.swift`, see `docs/DESIGN.md`); don't hard-code colors.
- Comments explain why, in plain sentences. Match the surrounding style.
- Keep debug hooks behind `OCTOMUX_DEBUG` (`DebugServer`, `UI/DebugActions.swift`).
