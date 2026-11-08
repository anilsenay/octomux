# Changelog

## Unreleased

- **Fixed: Octomux quit when an agent's browser tool call was cancelled** (or timed out) before its answer: writing
  the answer to the closed connection raised an exception the app couldn't catch. Such a call now just ends.

- **Option+Backspace deletes a word in Claude Code** (and Option with Delete, Return, Tab, Esc or an arrow reaches
  programs as Alt in the kitty keyboard mode they ask for). Option still types its characters (Option+Q is "@" on a
  Turkish keyboard): it counts as Alt only on keys where it doesn't change the character.

- **No dot on the agent you are watching**: a turn that ends (or a question, an error) while that agent is on screen in
  front of you is read at once — also with notifications off, for that project or that kind. Before, the green dot
  stayed until you switched away and back. A Home or file tab over it still leaves it unread.

- **Window**: the traffic lights are the size other current Mac apps have and sit on one line with the sidebar
  button, the bell and the tabs (the app is now built for the current macOS design, which also refreshes the
  system's own controls: switches, pop-ups and segments in Settings). Pop-up values in Settings are no longer in the
  accent color.

- **Layouts**: pick how the window is arranged for the way you work, for the whole app: **Terminal** (the window as
  it always was, still the default), **Agents** (the agents' window below; new Claude and Codex sessions open as
  chats) or **Tasks** (a window of its own, below). Switch with ⌃⌘1…3, the
  command palette (View → … Layout), or the Layout button the other layouts show in the status bar.
- **The Agents layout is a window of its own**: a rail of agents on the left by what they need from you (Waiting
  for you, Working, Done, Idle) with their last words and a project control (one project or all), a breadcrumb instead of tabs
  ("Home · Personal", "agent · project · branch" with a Chat / Terminal switch), and Home in the middle: a greeting,
  a big composer (project, checkout or a new worktree, agent), the agents waiting for you answered in place, recent
  sessions and usage (your Home, below). Home isn't a tab here: ⌘0 or ⌘T comes back to it. ⌘1…8 and ⌘[ / ⌘] move
  over the rail (⌘9: the last); after a click on the rail (or ⌥⌘A) ↑ ↓ ↩ do too.
- **Home, one page made of sections**: the same Home in the Agents layout and, as a tab, in the Terminal window
  (View → Home; one tab per project). Its ⌄ (after "Home", or on the tab) offers four presets — **Agents** (greeting,
  composer, waiting, recent, usage), **Workday** (your day: stats, waiting, while you were away, your pull requests,
  reviews and issues), **Board** (every agent in a column by state) and **Aquarium** (every agent as an octopus; ⌘T
  starts an agent) — and **Customize this Home…**: drag a section by its handle across the top row and the main and
  side columns, hide one with its eye, add one with + Add section, pick the page's width (Narrow · Wide · Full) and
  drag the line between the columns; each change is saved at once, Reset goes back to
  the preset. The agents waiting for you are rows in one card: the first is open with its answers, a click opens
  another, and answering opens the one that takes its place; ↑ ↓ move between them, 1 2 3 answer the open one and ↩
  opens it (while no field, terminal or the rail has the keys). Esc or leaving Home ends Customize. An opt-in Home row at the top of the sidebar (Settings
  → Layout → Sidebar) shows how many agents wait for you. Agents and Workday tabs from earlier builds open as Home.
- **The Tasks layout is a window of its own**: your tasks on a rail on the left by what they need from you (with
  status filters and a New task field, ⌘T), the assistant — or the picked task's agent — in the middle, and the
  picked task in detail on the right: its state, where it works, its agents and what they last said or ask, its pull
  request and source, subtasks and the next step. A project control above the rail shows one project's tasks (with
  icons, counts and a search field when there are many), New task has a project picker, and the sessions without a
  task are folded at the bottom of the rail. ⌘1…8 and ⌘[ / ⌘] go through the tasks (⌘9: the last), ⌘0 opens
  the assistant (and starts it when there is none).
- **Layouts as data**: every layout is a tree of rows, columns and stacks over Octomux's own blocks
  (agent rail, tasks rail, project tree, tabs, breadcrumb, work area, Home, side panel, task
  detail, agent column, aquarium, status bar), read from a JSON file; a tree that doesn't read or breaks a block's
  rules falls back to the built-in one. Terminal's tree draws the window it always was, to the pixel.
- **Your own layouts, as files**: Settings → Layout → Your layouts. Save the layout you arranged under a name, then
  switch to it from the View menu (⌃⌘8 and ⌃⌘9 for the first two by name) or the status bar's Layout panel. Export it as a small
  `.octomux-layout.json` (your theme and shortcuts too, if you tick them) and import someone else's: a sheet shows
  its window, name, author and base, and what this Mac can't use; its theme and shortcuts apply only if you tick
  them; the sheet lists each shortcut, and one on a key another command already has is left out. A file can't turn a
  command off or take ⌘Q, ⌘W, ⌘H, ⌘M or ⌘,. A layout file is data only — it arranges Octomux's own parts and can't
  run anything; a broken one (or one too big, too deep, or with a picture over 4096 px a side) is refused with the
  reason. Duplicate, delete, and use the window as a layout's picture.
- **Agent cards** (Home's Board): the agent's last words, the steps and files of its turn, and what it waits for:
  allow or deny a tool, or pick an answer, right on the card.
- **Workday** (a Home preset): your day on one page. Who
  needs you, answered right there; what happened while you were away (agents that finished, with the files they
  changed since you last looked, and automations that started work); your pull requests with their next step
  (fix the checks with an agent, mark ready, merge), reviews waiting for you, and your issues ("Work on it").
- **Work chips**: an agent's pull request (with its checks) and issue show next to it on cards, and in the pane
  header in the Agents layout (Settings → Layout → Pane header elsewhere).
- **Since you looked**: an agent card says how many files changed after you last looked at the agent, and lists
  them with their diffs.
- **Working on code with an agent** (the Editor layout has all of them; Settings → Layout turns them on anywhere):
  changed lines marked in the editor's gutter; a note on the selected lines ("Note to agent", ⌘⇧M) goes into the
  agent's message with the file, the lines and the code, for you to send; the Files panel lists what the agent
  touched in its current turn; and the project's agent can sit in a column beside the work area.
- **Tasks**: Octomux's own work items. Add one (or let the assistant split your request into several), start it,
  and it gets its own worktree, branch and agent; its state follows the agent and its pull request. Also from the
  command line (`octomux task …`) and for agents through the Octomux MCP tools (`task_create`, `task_list`,
  `task_start`…).
- **Workspace assistant**: your default agent with its editing tools off, as a planner. It turns what you ask into
  tasks and asks to start them; **Autopilot** decides how far it may go alone (off, start agents, or also open draft
  pull requests; never merging).
- **Default agent** (Settings → Agents) for tasks, the assistant and "Work on it"; each can be started once with
  another agent.
- **Aquarium**: every agent as a pixel octopus in its project's color, swimming while it works, with a "!" when it
  waits for you, asleep on the sand when it finished; click one to open it. A Home of the Agents layout (the
  agent rail beside it, ⌘0 back, ⌘T starts an agent) or a Home section; elsewhere a tab (View → Open Aquarium), a strip above the panes
  (its corner button opens the whole aquarium), a status bar button, or the Aquarium scene behind the sidebar.
- **Settings → Layout**: in each layout, turn off and reorder what the sidebar, its bottom row, the status bar and
  the top bar show; hide the status bar; open new agents as chats. Each layout keeps its own changes (Reset brings
  it back as it comes), and a layout can be exported to a file and imported on another Mac.
- **The right panel can be made wider**: drag its left edge (320 points until you do).
- Hiding the Keep Mac awake cup now belongs to the layout (it was per Mac); a hidden cup stays hidden.

## 0.4.0

Highlights:
- **Chat view**: full markdown, tool calls grouped per step, diffs, plans and questions as cards; answer a question
  or allow a tool right on its card; `/` and `@` menus, the model and a context ring in the composer, Stop.
- **Browser for agents**: Claude and Codex sessions get browser tools from Octomux's own MCP server; the page opens
  beside the agent's tab and you watch it click and type. Send any element of a page to an agent.
- **New look for the window**: a header on every pane, a git button that shows the next step (Commit, Push, Create
  PR, the open PR), Octomux's own panels for workspaces, Keep Mac awake and branch pickers, a start screen for new
  tabs and a **⌃Tab** tab switcher with pictures.
- **Keep Mac awake** while agents work (or always, or for a while), optionally with the lid closed, with limits.
- **Permissions**: sessions run under a small "Octomux Sessions" app, so macOS asks screen recording in its name.

All changes:

- **Start screen**: a new tab (New Chat) shows what waits for you and what ran last in the project, with starter
  chips; the composer stays at the bottom, in the same column as the chat, so nothing moves when it starts.
- **Every pane has a header** (also when a tab has one pane): which session and folder, with split, chat ↔
  terminal, browser and dock buttons. The top bar keeps the tabs and project-wide actions: diff, Open in and a git
  button that shows the next step: **Commit** (a panel with the changed files and a message the commit-message
  agent writes, Commit or Commit & Push, Amend), **Push ↑n**, **Create PR**, or the branch's open **PR #n** (from
  the Inbox, its checks' color). ▾ has all of them and Show Changes.
- **Workspace switcher and Keep Mac awake** open Octomux's own panels instead of system menus: each workspace with
  its color, what waits there and its shortcut; the cup shows what it does now, the modes, "for a while" and the
  closed-lid limits as chips. Arrow keys, ↩ and esc work as in a menu. The status bar's branch and Compare with pickers
  open the same kind of panel (no more system popovers), and every picker shares one look.
- **Readability**: with a scene, art passing behind the sidebar is drawn faint there (it no longer sits as
  bright as the rows' text); the Changes list keeps room for about five files when History is open; disabled Commit buttons
  are neutral (they couldn't be read in light themes). Translucent terminals over a scene default to 85% opacity (was 82%):
  the text reads better over the live scene.
- **Sidebar**: Search (⌘K) is the first row under the workspace, then Inbox and Projects.

- **⌃Tab tab switcher**: hold ⌃ and press Tab to see the project's tabs, most recent first, each with a picture of
  what it last showed, its activity and agent; ⌃⇧Tab goes back, letting go of ⌃ (or ↩) opens it, esc cancels.
- **Command palette**: without a query it is grouped (Waiting for you, Sessions, Commands); key hints and the
  result count at the bottom. Esc, arrows and ↩ work right away, even before the search field has focus.
- **Calmer window**: one Split menu in the top bar instead of two buttons, wider tabs (inactive tabs without a
  fill), usage limits as small rings in a slimmer status bar, segmented Files / Changes / Sessions tabs, open
  sessions marked with a dot instead of an "Open" badge.
- **New chat** suggests a few starters above the composer (they fill it, nothing is sent). Your messages in the
  chat view sit in a neutral bubble.
- **Consistent sizes**: one type scale and one corner-radius scale across the app (text that was half a point
  smaller is now whole sizes).

- **Chat view**: the conversation is drawn with full markdown (lists, tables, code blocks with highlighting and
  Copy), tool calls grouped per step ("Read 2 files · Ran 1 command") and folded once the turn ends, edit diffs,
  command output, todo lists, plans and questions as cards, "worked for" time per turn, and a "Latest" button
  when you scroll up (new messages no longer pull you down while you read).
- **Chat composers** grow with the text and scroll past 14 lines (wheel, trackpad); ↩ sends, ⇧↩ adds a line,
  pasted screenshots and files become attachments.
- **Chat composer** shows the model the session runs (Claude: switch it from there, sent as `/model`), a ring with
  how full the context is (Claude's own reading; Codex from its log), and a Stop button while the agent works.
- **`/` and `@` in the chat composers**: `/` lists built-in commands, your and the project's commands and skills,
  and enabled plugins' (Codex: built-ins and saved prompts), with descriptions; `@` finds files of the project
  (git's list) by name. ↑↓ to move, ↩ or ⇥ to pick, esc to close.
- **Answer from the chat**: when the agent asks one single-choice question, pick the answer on its card; when it
  waits for permission on a tool, Allow or Deny under that tool (sent to the terminal as the keys you would press).
  Messages you send while the agent works show as queued until it reads them.
- **Chat turns end with the files they changed** (lines added and removed, from the agent's own edits); click one
  to see it in Changes. Commands show the agent's own description ("Run tests") next to the command line.
- **Permissions for programs in sessions**: the daemon now runs from a small background app, “Octomux Sessions”,
  so when an agent takes a screenshot (or drives other apps) macOS asks in that name and remembers it, instead of
  blocking a nameless command line tool. Settings → Permissions shows screen recording and
  accessibility, asks for the first and opens System Settings for both.
- **Keep Mac awake** (Settings → Sessions, and the cup in the status bar): Off, While agents work (and two minutes
  after, so pauses between steps don't count) or Always. The display can still sleep. Optionally also with the lid
  closed: a one-time administrator prompt installs a rule that lets Octomux run only `pmset -a disablesleep`, set
  only while it keeps the Mac awake, on the power adapter unless you allow battery, and put back after (also after
  a crash).
  "For a while" keeps it awake 1–8 hours, then goes back to the mode before; the cup can be hidden (Settings brings
  it back).
  Closed-lid safety: at most a time you choose per lid closing (12 hours on the power adapter, 4 on battery by
  default; no limit possible on the adapter), never
  below 20% battery or under heavy thermal pressure; a notification says when a limit let the Mac sleep.
- **Changes panel** has "Compare with" at the top: the same branch choice as the status bar's "→ branch".
- **Browser for agents**: Claude and Codex sessions get browser tools (open a page, read it as an accessibility
  snapshot, click, type, press keys, choose options, wait, run a script, read the console, take screenshots, switch
  pages) from Octomux's own MCP server, added to each session as it starts; your MCP settings stay as they are
  (Settings → MCP turns it off). The page opens beside the agent's tab, half the width (drag its edge), and you
  watch the agent work: its cursor glides to the element, a band says who acts and what ("Claude · Fix login —
  Clicking “Sign in”"), and the element is framed. The globe in the top bar shows or hides the browser of a tab;
  you can browse yourself (address bar, back, forward) and hand a page to an agent. Each session works in its own
  page; pages keep cookies apart from your other browsers and come back after a relaunch.
- **Send an element to an agent**: the browser's pick button (target) highlights what's under the pointer; click
  one, add a note, and it goes to an agent's message box (the tab's, or one you choose; terminal or chat view) with
  its selector, role and name, text, main styles, the page and a crop of it, for you to read and send.
- **Links in terminals and the chat view** to local addresses (localhost, 127.0.0.1, *.local…) open in the
  browser beside the tab, or bring forward the page already showing them; others still open in your default
  browser. Settings → MCP → Octomux browser picks which (local, all web links, none); ⇧-click does the other.
- **Browser basics**: find in page (⌘F, with the number of matches), zoom (⌘+ ⌘− ⌘0), ⌘L for the address bar,
  ⌘[ ⌘] back and forward, ⌘R reload, only while the page has the keyboard; address suggestions from the pages
  you visited (↑↓ ↩); a page that can't load says why, with Try Again; downloads go to ~/Downloads, listed under
  the browser's download button with Show in Finder; screen sizes (mobile, tablet, laptop, desktop) the page is
  laid out at, scaled to fit.
- **Agents hear what their actions changed**: a new address or title, pages opened, downloads, new console errors
  (each once). On long pages a result carries only the lines that changed (said so, with their parents), the whole
  page when it is new or small; browser_snapshot takes `diff`. New tool browser_resize for mobile/tablet layouts.
- **Who may use the browser**: Settings → MCP → Octomux browser: Off, Ask (a session asks the first time; your
  answer holds for it, listed in Settings to forget) or On, and an optional list of allowed sites (wildcards):
  agents can't open others, nor follow links to them.
- Fixed: two background services could start at once for the same data (the app and a command starting it at
  the same moment); the extra one kept running unseen. Now only one starts, and a leftover one stops by itself.
- Fixed: the chat composer could freeze or close Octomux when a long text arrived in it (a pasted log, an element
  from the browser).

## 0.3.0

Highlights:
- **Inbox** in the sidebar: pull requests waiting for your review, your own pull requests with their checks, and
  issues assigned to you, from **GitHub**, **Jira Cloud** and **Bitbucket Cloud**, with notifications, activity,
  snooze, keyboard, and changes you can make from there (each asked first).
- **Agents on Inbox items**: Work on it, Ask, Summarize, Fix with agent, and **Review** a pull request in the
  background (read-only by default, a download when you have no clone), then post its findings as review comments.
- **Changes view**: diffs by line like git, a resizable split, sticky file headers, scroll bars a mouse can reach,
  wrapped lines on request, and the panel follows the branch you compare against.
- **Resume with Flags…** to bring a stopped agent back with other flags (`--chrome`, a model…).
- **Workspace paging** with a two-finger swipe over the sidebar.

All changes:

- **Changes panel follows the compare branch**: with a branch picked next to the status bar's branch, the panel
  lists every file since it (committed on this branch or not) under **Since <branch>**, with the same counts as
  the status bar; a click opens that file's diff against the branch. Before, it showed only uncommitted files.
- **Diffs by line, like git**: a file with many changes no longer shows untouched lines as removed and added
  again; the Changes view now matches the +/− counts, with word marks inside the lines that did change.
- Changes view: in split mode drag the bar between the sides to resize them (every file follows; double-click
  for half and half), and each file's header stays at the top while you scroll through it. A file's horizontal
  scroll bar stays at the bottom of the window while the file is on screen (one per side in split mode, over
  the code, shown while the pointer is on that side), so a mouse can scroll long lines; **↩** wraps them instead (kept for next time); line numbers no longer show code through them when it scrolls sideways.
- **Resume with Flags…** next to Resume on a stopped agent: add flags (`--chrome`, a model…) by hand or with
  checkboxes for common ones; the conversation goes on where it stopped and the flags stay for later resumes.
- Closing a tab goes back to the tab you were on before it, not to the first one.
- Names cut short show in full on hover: a project's row (name, branch, folder) and the Changes panel's files.
- **Workspace paging**: a two-finger swipe over the sidebar pulls the next workspace's projects in beside the
  current ones, and the window color blends toward the new workspace's as you pass the middle. Let go past
  the point (or flick) and it switches; otherwise it springs back. ⌃⌘← →, ⌃1…⌃9 and the switcher dots page too.
- **Inbox** (sidebar, above the projects): pull requests that wait for your review, your pull requests with their
  checks, and issues assigned to you, from **GitHub** (through the GitHub CLI, so Octomux keeps no GitHub token)
  and **Jira Cloud** (site, email and an API token, with or without scopes, kept in your Keychain).
  - Folders by why something is there and where it comes from (collapsible to icons); filters by source,
    time and text; hide repos and projects; read and unread marks; comments to read and write.
  - **Work on it** opens a new tab with the item as the prompt, or starts the agent in a new worktree on the
    item's branch; **Review** a pull request in the background or in a chat; **Fix with agent** when checks
    failed. The session stays linked to the item (Go to session).
  - Notifications for review requests, failed checks, new assignments and changes to your things; ring the
    bell on a Jira project to hear about every change there, by anyone: a sound only (no banner) unless you
    choose banners. Checked every 1–10 minutes. Their sound is picked in Settings → Notifications (Sound: Inbox,
    Blow unless you change it).
  - **Activity**: an item's comments, Jira changes (status, assignee, priority, sprint, title, description; who and
    when) and GitHub events (commits, reviews, review requests, labels, assignees, merge/close, renames,
    force-pushes) in one timeline, with a **New** line where you left off and a "Since you looked" summary on
    top. Notifications say who did what ("DC-12: Ann moved it to Code Review"); changes you made yourself on the
    website are no news. When the Jira token can't read the history, comments still show, with a note.
  - **News in linked sessions**: when someone comments, reviews, pushes or moves an item you sent to an agent, a
    card in that session's pane says what changed; **Tell the agent** pastes it in (as reference data, for you
    to send), **Open in Inbox** shows the item.
  - **Fix with agent** reads what the failed checks printed first (the failed steps of GitHub Actions jobs, or
    another check's own summary), and hands it to the agent with the prompt (up to 12,000 characters). A line
    under the checks follows the fix: prompt waiting, agent working or waiting for you, checks running again,
    checks pass.
  - **Merged, closed and done items stay a while**: something that leaves the open searches because it was
    merged, closed or finished stays in the list with that label for three days (a week when an agent worked on
    it), with a notification and a note in its linked session. Items that only left a search (a review request
    withdrawn) still go quietly.
  - **Keyboard**: ↑ ↓ (or k j) move through the list, Return opens the first item, Esc closes it, u marks it read or
    unread, s sends it to an agent, o opens it on the website, r refreshes, / filters (Esc clears, Esc again
    leaves the field). The keyboard button lists them.
  - **Ask** (button, or the a key): a chat about the item that only reads: the agent starts with the item as
    reference data and your question at the end, in Claude's plan mode or Codex's read-only sandbox, apart from
    any session working on the item. Continue asking goes back to it.
  - **Images** in descriptions and comments: GitHub's own images (loaded without any credentials) and Jira
    attachments (from your Jira only). Images from other sites aren't loaded, since they could tell the sender you
    opened the item; they show as a link. Jira requests no longer follow a redirect to another host.
  - **Code tab** on a pull request: its changed files with their counts, each one's changes with line numbers
    (small files open, big ones closed; long ones show the first 400 lines until you ask for all).
  - **Pull Request menu** in the detail: merge (merge commit, squash or rebase, into the named base branch), mark
    ready, convert to draft, close or reopen, through the GitHub CLI. Each one asks first, saying exactly what will
    happen; the branch is never deleted. A merge or close made here is no news in your notifications.
  - **Jira from the Inbox**: change an issue's status through its workflow (the status chip is a menu), assign
    it to yourself, or create a new issue (the pencil in the Inbox bar), each after a confirmation. Starred Jira
    filters can bring their open issues in (Settings → Inbox → What shows up), under From your filters. What
    the agent is asked for a Jira issue is a template in Settings ({key}, {title}, {status}, {project}, {url},
    {assignee}).
  - **Mute a bell for a while**: right-click a project's bell (in the Inbox or in Settings) to quiet it for an
    hour, until tomorrow 09:00, until a date you pick, or until you turn it back on; Settings can mute every bell
    at once. A muted bell shows struck through; its changes still wait unread in the Inbox.
  - **Automations** (Settings → Inbox → Automations): rules that start an agent by themselves when a matching
    item comes in (from, what, why, where), either reviewing a pull request read-only or working on the item in
    a new worktree, in the item's own project and without switching to it. Rules are off until you turn them on
    (and confirm); each item starts at most once per rule, at most three per check, and only new arrivals count.
  - **Bitbucket Cloud**: pull requests that wait for your review and your own ones, with their builds and how many
    approved or asked for changes, next to GitHub's. Connect with an Atlassian API token with Bitbucket scopes
    (read:user, read:workspace, read:repository, read:pullrequest); it is kept in your Keychain and sent only to
    api.bitbucket.org. Bitbucket can't list your review requests across a workspace, so the repos updated in the
    last two weeks (and those of your projects) are checked every 10 minutes, and repos holding one of your pull
    requests on every check, within Bitbucket's hourly allowance (it slows down when Bitbucket asks). A review
    request you approved leaves the list until new commits come. The detail has the description, Activity
    (comments, inline comments with their file and line, approvals, changes asked for, pushes, merge/decline),
    the Code tab and the builds; declined and superseded pull requests stay a while like merged ones. Settings →
    Inbox picks the workspaces and repos, and can look in every repo instead.
  - **Agents on Bitbucket pull requests**: Work on it, Review, Fix with agent and Ask work on them
    too; the branch comes through git with your own credentials (the token never goes to git), and Fix starts
    from what the failed builds reported. Linked sessions hear about new comments, approvals and pushes,
    notifications say who did what ("#7: Ann approved"), and automations can pick Bitbucket as their source.
  - **Change Bitbucket pull requests from the Inbox** (Pull Request menu, each asked first): approve or take it back,
    request changes or withdraw it, merge (merge commit, squash or fast-forward; the branch stays), decline, and
    comment. Needs write:pullrequest on the token. **Fix with agent** reads the failed steps' logs of a Pipelines
    build (with read:pipeline); the log's storage link is followed without the token.
  - **Comment counts** on pull requests and issues (GitHub and Bitbucket) next to approvals and changes asked for, in
    the list and the detail. Descriptions no longer show Markdown link definitions ("[id]: https://…", where
    review bots hide notes), and a heading inside a quote reads as one.
  - **Activity that reads faster**: long comments show their first lines with Show more, review bots' reports
    start folded to one line (marked "bot"), new ones always open; Collapse all / Expand all, and Newest first
    (with an "Earlier" line under what is new). "Jump to new" on the "Since you looked" card. An inline comment's
    file opens in the Code tab. Quotes show as quotes, with a bar.
  - The detail says where your review stands on a review request (and who asked, when GitHub says), and a Jira
    issue named by a pull request shows its title and status even when it isn't in your Inbox. "Open in…" moved
    next to Mark unread.
  - Settings → Inbox lists the Bitbucket repos read for review requests too, with how many items each holds;
    an unticked one is no longer read.
  - **Review in the background** (pull requests on GitHub and Bitbucket): the pull request's head is checked out in a
    worktree of its own (detached: no branch of yours is made or moved; setup scripts skipped) and an agent that
    may only read (Claude: reading and git diff/log/show only, no edits or writes; Codex: read-only sandbox) reviews
    it there. Its summary, risk and findings (each with its file and line, which opens in the Code tab) show in the
    item's Agent review card, with a notification when it is ready. Nothing is posted. Two run at a time; the
    worktree goes when the pull request is merged, declined or closed (when nothing in it changed). An automation
    can do it for new review requests ("Review it in a worktree"): drafts, ones you approved and ones over 3,000
    changed lines are skipped, and it doesn't take over the window. When such a pull request gets new commits,
    the rule reviews what changed (once per new head, while it is on); reviews you started stay yours to repeat.
  - The detail's buttons in two rows. The first holds what reads or changes code: Review (in the background or in a
    chat; the arrow picks, the button does your default), Work on it and Ask, all "in" the project picked
    beside them. That picker offers the pull request's clones first, marks another repo's project, and says
    "No local clone" rather than falling back to the open project. The second row holds what needs no code
    (Summarize, the Pull Request menu). A review request puts Review first; your own pull request and issues
    put Work on it first. A review in a chat asks first in a project that isn't a clone of the repo (Return
    cancels). "Use an Existing Folder…" in the picker adds a folder you pick as a project, in the
    workspace you pick (it says so if the folder is another repo's), and uses it for that repo. "Clone
    Repository…" clones the repo (folder and workspace picked in one dialog; the last folder is remembered) and
    does the same once it is done, with "Cloning…" in the picker meanwhile; the picker's Cancel Cloning stops
    it and removes what it wrote. A background review's download can be cancelled from its card too. Clones in
    other workspaces count too. The detail header's counts wrap as whole labels in a narrow window.
  - A background review of a repo you have no local clone of downloads one (asked first): a partial clone, so
    only the history without file contents and the files of the pull request's head come down, no Git LFS
    files, with your own git access (it fails rather than asking for a password). It stays for later reviews
    of that repo and goes after 7 days without one; Settings → Inbox shows their size and removes them.
    Automations still review only in local clones.
  - **Restricted reviews** (Settings → Inbox, on to start with): the background review's agent may only read.
    Claude has just Read, Grep, Glob and Bash, loads no settings file (neither yours, whose permissions could let
    it run a command on the pull request's code, nor the pull request's own) and no MCP server; Bash runs git's
    reading commands. Codex reads in its read-only sandbox, without the pull request's .codex folder. Turned
    off, the review runs as your sessions do, with your settings and permissions.
  - Background reviews now run in the app as they were meant to. Claude gets its read-only tool limits as flags
    (the settings they were passed in never reached it, so it ran with your usual permissions) and runs in
    print mode; Codex runs as `codex exec`. Before, both stopped at their "trust this folder?" question in
    every new review folder and the review hung until its time ran out.
  - The background review's Claude loads only your own settings and MCP servers: a pull request that adds hooks to
    its .claude settings or servers to its .mcp.json can no longer run them during the review. Its .codex folder
    is left out of the review's checkout: Codex loads it (MCP servers, notify commands) whenever your clone is a
    trusted Codex project, and no flag turns that off. The agent can still read it with git show.
  - Resuming an Inbox review's session continues the conversation (it runs interactively, with the same limits);
    before, it started in print mode with no prompt and exited at once with code 1. The next review of a pull
    request closes the earlier review sessions that have stopped, so they don't pile up.
  - Hide from Sidebar hides a worktree that has sessions in it too (it came straight back before); its sessions
    stay in the Agents list. The project's menu (right-click it) shows hidden worktrees again, review folders
    of downloaded clones included.
  - Workspaces keep their order: Move Up / Down could give two workspaces the same position, so the order
    changed after a relaunch and moves jumped. Moving now renumbers them (mending old ties), and Settings →
    Workspaces rows can be dragged by their handle.
  - The Inbox remembers its source tab, folder, time range and the Snoozed folder across relaunches.
  - The sidebar shows a project's branch right after its name, with a branch mark. When room runs short the name
    shortens first while the branch stays whole, then both shorten; badges and the hover buttons keep their
    size. Before, the branch was capped at a few characters even with room to spare.
  - The Inbox opens in a workspace that has no project yet (in place of its "add a project" screen); before,
    clicking it did nothing there.
  - The Inbox's folders and list are resized by dragging their right edge (a double click puts one back); the
    widths are kept, and the detail never gets narrower than it can show.
  - After a launch the Inbox shows the lists from the last run at once (kept for up to three days, connected
    sources only) and says it is updating them; the first fetch replaces them and nothing rings for the kept
    ones. A source loading with nothing kept says so ("Loading Bitbucket…") instead of showing nothing or
    "Nothing matches.".
  - Confirmations of changes others see (merge, decline, approve, posting a review, Jira changes) take a click:
    Return no longer confirms them, Escape cancels.
  - **Post a review's findings**: each finding on the Agent review card has a box (issues and suggestions are
    ticked to start with; questions and nits wait for you). Post Comments… shows every comment first, editable,
    with where it goes: on its line when the change shows that line, else in the review's text. Add the
    review's summary if you like (off to start with) and pick a verdict (comment only, approve, request
    changes; not on your own pull request); nothing goes until you confirm. GitHub gets one review anchored to
    the commit that was reviewed; Bitbucket gets a comment each and then the verdict, and is not posted to
    once new commits came since the review (Review New Commits first). Posted findings are marked with a link
    and not offered again; one that still stands after Review New Commits stays marked.
  - **Review New Commits**: after a background review, the next one looks at what changed since (the new
    commits on top, with the rest of the change for context) and checks the earlier findings: the card says
    what was fixed (struck through) and marks new findings. A rebase or force push gets the whole change
    reviewed again, still checking the earlier findings; no new commits keeps the last review. Review All
    starts from scratch. GitHub pull requests now carry their head commit too, so "new commits since" shows
    for them, and it no longer shows for every Bitbucket review (a short and a full hash of the same commit).
  - **Bitbucket tasks and reviewers**: a pull request shows how many open tasks it has (the reviewers' to-dos), and
    its detail lists them; a click marks one resolved or opens it again (asked first). Work on it and Fix with
    agent hand the open ones to the agent. The detail lists the reviewers with where each one's review stands.
  - **Summarize** (✨ in the detail): your own agent CLI (the one picked for commit messages; no tools, nothing
    kept) reads the item and its history and says where it stands, what happened and what waits on whom, you
    first, in the item's language. The card says when the item changed since; Summarize Again redoes it.
  - **More Jira changes from the Inbox**, each asked first: assign an issue to anyone (search by name) or unassign it
    (the assignee is a menu), change its priority (a chip next to the status, with the priorities its screen
    allows), rename it (the pencil by the title) and edit a plain description. A description with formatting
    (lists, links, images) isn't edited here, so nothing in it is lost: Edit on Jira opens it there.
  - **Snooze** an item (the moon in the detail, or z for tomorrow morning): later today, tomorrow, next week or a
    date you pick. It leaves the list and the count until then, comes back unread with a notification, or sooner
    when something happens to it. The Snoozed folder lists them; Unsnooze brings one back.
  - **Jira issues named by pull requests**: a pull request whose title or branch names a Jira issue
    (feature/SHOP-7-…) shows it under the header, with its status; the issue shows its pull requests. The agent's
    prompt names the issue too.
  - Fixed: old items you had read (last updated two months ago or more) could come back unread after a relaunch
    when the other source loaded first.
  - Settings → Inbox: connections, Jira projects, GitHub repositories, what shows up, notifications, and what
    Work on it opens.

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
