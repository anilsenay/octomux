# Changelog

## Unreleased

- **Inbox** (sidebar, above the projects): pull requests that wait for your review, your pull requests with their
  checks, and issues assigned to you, from **GitHub** (through the GitHub CLI, so Octomux keeps no GitHub token)
  and **Jira Cloud** (site, email and an API token, with or without scopes, kept in your Keychain).
  - Folders by why something is there and where it comes from (collapsible to icons); filters by source,
    time and text; hide repos and projects; read and unread marks; comments to read and write.
  - **Send to agent** opens a new tab with the item as the prompt, or starts the agent in a new worktree on the
    item's branch; **Review with agent** for review requests, **Fix with agent** when checks failed. The session
    stays linked to the item (Go to session).
  - Notifications for review requests, failed checks, new assignments and changes to your things; ring the
    bell on a Jira project to hear about every change there, by anyone. Checked every 1–10 minutes.
  - Settings → Inbox: connections, Jira projects, GitHub repositories, what shows up, notifications, and what
    Send to agent opens.

## 0.2.0

Highlights:
- **Sessions outlive their tab.** Closing a tab or pane leaves its sessions running in the sidebar; Stop and
  Remove there end them (Stop asks first when something is still running). Settings → Sessions can make
  terminals end with their tab again.
- **Create Pull Request** from the Changes panel, ✨ commit messages and PR text written by your own agent CLI,
  Discard changes, and Ask Agent about a change.
- **Quick composer** over any app, **Prompts** you save once, an **MCP** page to see, check, add and remove servers.
- **Worktrees** with setup and teardown scripts, branch name patterns and a custom root.
- A rebuilt **Settings** with search, and pages for Terminal, Sessions (CPU and memory per session), Projects,
  MCP, Prompts and more; interface size 90–120%.
- **Codex** at the same level as Claude Code; Intel Macs; Homebrew.

All changes:

- **Workspaces that want you** in the sidebar's switcher: a mark in amber (something waits for your input there)
  or green (finished while you were away), as a bar under the workspace, a glow behind it (each still or slowly
  breathing), a corner dot or a count (Settings → Appearance → Sidebar). It replaces the small corner dot, which is still one of the choices.
- **Add MCP servers** from Settings → MCP (Add Server… on each agent's group): a command or an HTTP/SSE URL,
  environment variables or headers, and for Claude Code where it applies (all projects, one project, or the
  project's shared .mcp.json). Runs the agent's own `mcp add`.
- **Sessions outlive their tab:** closing a tab or pane (×, ⌘W) leaves its sessions, agents and terminals alike, in
  the sidebar and still running; clicking one opens it in a tab again. A session ends with Stop and Remove in the
  sidebar, and Stop now asks first when a program (a dev server, `sleep`) or a busy agent would be stopped
  (Settings → Terminal → Ask before stopping a running program). The first time a closed tab leaves something
  running, a note says where it went. Settings → Sessions → Closing a terminal tab can make terminals end with
  their tab instead, as in other terminal apps (asking first when a program runs).
- **Discard changes** in the Changes panel: per file (hover, or right-click) and for a whole group, after a
  confirmation. New files go to the Trash.
- **Preview tabs:** a click in the Files panel opens the file in a preview tab (italic) that the next file
  replaces; double-click the file or the tab, or edit it, to keep it.
- Ask before stopping now sees programs behind shell wrappers that run your shell in a terminal of their own (it
  saw nothing there). A program whose binary is named after its version (Claude Code) shows by its name.
- Buttons now take clicks on their whole area, not only on their text or icon (the − / + in Settings → Terminal,
  bordered buttons across Settings).
- The Settings sidebar no longer jumps when you switch pages (the previous page's sections showed for a moment);
  the MCP page, whose sections load after it opens, no longer lists them there.
- MCP Check also lists the servers Claude Code gets from your claude.ai account and plugins, with their status.
- With Codex as the commit-message agent, its model is picked from the models your Codex offers.
- Recording the quick composer shortcut no longer opens the composer when you press the current one.
- **Agent events** (Settings → Advanced, or a tab's right-click → Show Agent Events): the last 500 hooks,
  agents' own status reports and state changes, with time and session; also in the diagnostics zip.
- **Close stopped agent tabs** after 1 hour to 1 week (Settings → Sessions, off by default); pinned tabs stay and
  the session stays in the sidebar, where Resume opens it again.
- **MCP page:** Check shows whether each Claude Code server connects (`claude mcp list`), and Remove takes a
  server out with the agent's own `mcp remove`.
- **Create Pull Request** (Changes panel ▾, ⌘K): base branch, title, description and Draft; ✨ writes the title and
  description from the branch's commits and diff. Pushes the branch and runs `gh pr create`, or opens GitHub's
  compare page filled in when `gh` isn't available.
- **Interface size:** 90–120% for the window's text and rows (Settings → Appearance), separate from the terminal
  font size.
- **Worktree branch names:** a pattern fills the name in (`{user}/{date}-{n}`, Settings → Projects), and ✨ in the
  New Worktree window names the branch from the task you give the agent (the task is its first message).
- **Tab titles from your first message:** Settings → Sessions can name agent tabs after the first message you
  sent instead of the agent's own conversation title. Works for Claude Code and Codex.
- **Diff colors:** blue and orange instead of green and red (Settings → Appearance → Diffs), everywhere added and
  removed lines or counts show.
- **Status bar limits:** show all, only the 5-hour or only the weekly limit (Settings → Agents → Usage limits).
- **Default app for files:** files open in their macOS default app or an editor you pick (Settings → General →
  Open in); "Open in …" on files in the Files panel and Changes.
- The added-line marker in diffs now takes the theme's color (it was always the default green).
- **✨ Commit messages:** the sparkles in the Changes panel's message box ask an agent for a commit message from
  the staged changes (or all of them) and the repository's recent commit style. Your own `claude` or `codex` CLI
  runs once in the background (no tools, nothing saved, hooks and MCP off); the agent, model (Claude: Haiku) and
  a style are set in Settings → Projects. Click again to stop.
- **Ask Agent in the Changes panel:** prompts marked for it show in a menu on the panel and on each changed
  file (`{file}`, `{base}`), and go to the focused agent when it is free there, else to a new one.
- **Prompts:** save prompts you send often (Settings → Prompts) for every project, a workspace or one project,
  and pick them in a new chat, the quick composer or ⌘K. `{project}`, `{path}`, `{branch}`, `{clipboard}` and
  `{date}` are filled in.
- **Quick composer:** a small window over any app to start an agent: project, agent, prompt, Return. You stay
  in the app you were in (⌘Return brings Octomux forward instead). Set a shortcut that works everywhere in
  Settings → Keyboard → Anywhere; it is also in the File menu and the menu bar icon's menu.
- **Settings → MCP:** the MCP servers Claude Code and Codex start with, per agent config (agents that share a
  config share a list): all projects or only one, shared `.mcp.json` servers and whether they are approved,
  servers turned off, and the command or URL. Read only; values of environment variables and headers are not
  shown.
- **Settings → Projects:** a project's name, folder, color and icon in one place (also from its right-click
  menu, Project Settings…), where its worktrees go, and setup / teardown scripts for its worktrees (setup runs in
  the dock after a worktree is created, teardown before it is removed; both get the project, worktree and
  branch as variables). A worktree folder can also be set for all projects.
- **Remove Worktree** can delete the branch as well ("Also delete the branch", default per project); a branch
  that isn't merged asks before it goes.
- **Settings → Sessions:** every running session with the CPU and memory of its processes (shell or agent plus
  what it started), with Open and Stop. "Stop idle agents" (off by default: 15 min to 4 hours) stops agents
  that finished and sat without output; Resume continues them. Terminals are never stopped for being idle.
- **Save diagnostics** (Settings → Advanced): a zip with versions, state, settings, terminal.conf and the end of
  the logs, tokens, keys, passwords and email addresses removed.
- **Agent start options:** editing an agent in Settings → Agents sets its model, effort and permission mode
  (Claude Code) or model, effort, approvals and sandbox (Codex) from lists. They become flags in its Arguments.
- **Open in:** Settings → General lists the apps for every Open in menu: reorder them, hide some, add any other
  app, and pick the default for ⌘O. The menus have an "Edit This List…" item.
- **Notifications:** Send Test in Settings → Notifications, and a sound for each kind (agent finished, needs
  input, error, commands and programs), picked from the macOS alert sounds; picking one plays it. Sound and
  other notification settings now follow the project the notification is about, not the one on screen.
- **Usage meters** can show what is left instead of what is used (Used / Left in their popover, or Settings →
  Agents → Usage limits). The color still warns at 70% and 90% used.
- **Settings → Terminal:** font (installed monospaced fonts or the built-in JetBrains Mono), size, line height,
  cursor style and blink, and scrollback lines, with a preview; terminals change as you pick. The terminal.conf
  editor moved here from Appearance and keeps working for everything else.
- **Settings → Keyboard:** Find by Keys (press a combination to see what it does), an "Acts on" column (focused
  pane, current project, …) and Reset All Shortcuts. Shortcuts with Return show ↩.
- **Agents panel filter:** its menu can show only the current workspace's agents.
- **Settings, rearranged:** pages in groups (App, Work, Advanced), a search field that jumps to the setting,
  every setting with a line on what it does and its control on the right, and the Global / Workspace switch at
  the top of the pages a workspace can override (a dot marks what it overrides, Reset goes back to Global). The
  current page's sections are listed under it in the sidebar. Choices you can see are picked from previews: window
  mode, terminal colors, split tabs, what shows behind terminals, workspace color, and the Dock and menu bar icons.
  A new General page has the version and Check for Updates.
- **App icon:** Settings → Appearance → Icons, Color or Monochrome (a white and grey octopus on a charcoal
  tile). It changes the Dock icon while Octomux runs.
- **Shells still running:** when Claude ends its turn with commands still running in the background (a build it
  waits for, a dev server it left up), the session shows a terminal mark with their count, stays under Finished,
  and the notification says "1 shell still running". When they end, Claude goes on by itself as before.
- Every status mark (dots, badges, counts) explains itself on hover.
- **Intel Macs:** the app is universal now (Apple Silicon and Intel).
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
