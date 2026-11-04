# Changelog

## Unreleased

- **Homebrew:** `brew install --cask anilsenay/tap/octomux`, and `brew uninstall --zap --cask octomux` removes
  everything. The cask follows each release.
- **Codex at the same level as Claude Code.** Working, waiting for approval and done for Codex 0.164 and
  later (it reports its state itself, no hooks or setup), also for a `codex` typed in a terminal tab. The tab
  takes the conversation's name, the chat view and Copy Transcript Path follow the running conversation, and a
  terminal tab restored after a stop or reboot reopens its Codex conversation with `codex resume`. Older Codex
  versions show working and done from their rollout file; Settings → Agents shows the version and what it
  supports.
- Chat view: Codex's newer tool calls (code mode) show as tool cards, and the context Codex adds to the first
  message (AGENTS.md, environment) is no longer shown as your message.
- Usage limits for Codex come from that profile's own running conversation.
- A terminal tab whose agent conversation is reopened on restore keeps it while the agent is still starting.
- Codex waiting at its startup screens (trust this folder, review new hooks, update) shows as needing input.
- Codex follows /new, /fork and /resume to the conversation you are in, and ignores the files of its subagents.
- Sessions started in Octomux no longer inherit the variables Codex sets in its own shells.
- A `claude` or `codex` typed in a terminal tab is reopened on restore with the flags it was started with (model,
  permission or sandbox mode, extra directories, config), but not its first prompt.

## 0.1.2

- While Octomux connects to its background service at launch (a few seconds right after an update), the window
  shows "Starting Octomux…" instead of an empty sidebar.
- The Claude Code integration's hook only answers in its own app's tabs, so Octomux and Octomux Dev can both
  have it on.
- For contributors: **Octomux Dev** (`tools/build-app.sh release dev`), a separate app with its own data and
  background service that runs next to an installed Octomux.
- Updated SQLite bindings (rusqlite 0.41) and signal-hook 0.4.

## 0.1.1

- Only one copy of Octomux runs at a time: opening a second copy (say, one in Downloads and one in
  Applications) asks which one to keep, instead of both taking over the background service.
- The background service follows the copy you open, once at launch; a copy that was left open no longer takes
  it back when it reconnects.

## 0.1.0 — first public release

- Sessions in a background daemon (launchd agent, one holder per session): they survive app quits, crashes,
  updates and daemon restarts; Claude Code and Codex resume their conversation after a reboot.
- Workspaces, projects, tabs, splits, dock; git worktrees; the right panel (Files, Changes with History, Sessions).
- Claude Code status (working / needs input / done), notifications, menu bar panel, chat view.
- Usage limits for Claude Code and Codex.
- Remote hosts over SSH.
- Themes, dark by default, and animated scenes (Octo Deep, Kraken, Tide Pool and more).
- Signed, notarized, and updates itself (Sparkle) without stopping your sessions.
