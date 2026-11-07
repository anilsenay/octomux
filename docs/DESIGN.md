# Octomux design system

Source of truth in code: `app/Sources/Octomux/UI/Theme.swift` (tokens + presets) and
`app/Sources/Octomux/UI/Components.swift` (shared components). Directions explored: `design/directions/`
and the artifact linked in DECISIONS D9. Default preset: **Ink**. Others: **Grid**, **Glass**
(Settings → Appearance). Mode: System / Dark / Light.

## Principles
1. **One surface family.** Chrome (sidebar, bars) and terminal share a hue; the terminal is never a
   foreign dark rectangle inside a light frame.
2. **Content in cards, chrome flat.** Terminals and the dock sit in rounded inset cards (Ink/Glass) or
   edge-to-edge with hairlines (Grid). Chrome has no borders of its own except hairlines.
3. **Color means state.** Accent = selection / working. Amber = needs input. Green = done / success.
   Red = error / removed. Never decorative.
4. **Quiet until needed.** Row actions appear on hover; counts appear only when > 0.

## Color tokens
All tokens exist for dark and light. Values below are Ink; Grid/Glass in `Theme.swift`.

| token | role | Ink dark | Ink light |
|---|---|---|---|
| `frame` | window ground, sidebar, bars | `#141416` | `#ECEBE8` |
| `surface` | terminal / dock card, settings content | `#1B1B1F` | `#FBFBFA` |
| `raised` | active tab, popover, chips | `#27272C` | `#FFFFFF` |
| `hover` | row / button hover | white 5% | black 4.5% |
| `selection` | selected row | accent 14% | accent 11% |
| `border` | hairlines, card edges | white 7% | black 8% |
| `text` / `text2` / `text3` | primary / secondary / tertiary | `#EDEDEF` `#A6A6AF` `#8B8B94` | `#1D1D1F` `#55555C` `#6B6B73` |
| `accent` | selection, working, primary button | `#EB8A5E` | `#C9592B` |
| `claude` | Claude agent mark | `#E8875B` | `#C9592B` |
| `amber` | needs input | `#E9B949` | `#9A6200` |
| `green` / `red` / `blue` | done/added, error/removed, info | `#5DCB8E` `#F27474` `#74A9F8` | `#1E8A4C` `#C93838` `#2A6BD1` |

Project tile colors: the existing 9-color palette (`Palette.colors`).

## Typography
System font (SF Pro) in the app; Inter only in mockups. Mono: JetBrains Mono if installed, else SF Mono.
A closed scale with no half points (`DesignTokenTests` fails on `N.5` sizes in `UI/`):

| style | size / weight | use |
|---|---|---|
| `display` | 22 / bold | empty-state titles |
| `title` | 20 / bold | settings page title |
| `heading` | 15 / semibold | panel and card titles |
| `body` / `headline` | 13 / regular, semibold | rows, menus, sidebar; project names |
| `ui` (`small`) | 12 / medium | tabs, buttons, segmented tabs, right-panel rows |
| `meta` (`caption`) | 11 / medium | ages, second lines, status bar, badges |
| `micro` / `label` | 10 / semibold, uppercase, +0.6 tracking (Grid: mono) | section labels, counts |
| `mono` | 11–13 / regular | branch, diff stats, commands |
| `icon(n)` | glyph-only sizes (7–9 for tiny marks) | SF Symbols inside buttons and badges |

## Spacing, radius, elevation, motion
- Spacing (`S`): 2, 4, 6, 8, 12, 16, 20, 24, 32.
- Radius (`R`): `xs` 4 (badges), `sm` 6 (icon buttons, menu items), `md` 8 (rows, buttons, inputs, tabs),
  `lg` 10 (cards, popovers), `xl` 12 (panels), `float` 14 (palette, tab switcher, toasts). Lines and indicators
  below 4 keep their own values; `DesignTokenTests` fails on other radii.
- Rows: 30 px (Grid 24), radius 8 (Grid 2). Tabs: 28 px (Grid: 36 px underline; Glass: segmented).
  Top bar 46 px, status bar 28 px (Grid 36 / 24, Glass 48 / 32).
- Cards: radius 12 (Glass 12, Grid 0), 1 px `border`, inset 8 px from the window edge, 8 px gap between panes.
- Shadows only on floating things: active pill tab (light), segmented-tab thumb, popovers/menus (system),
  palette and tab switcher (0 16 36 black 35% + 1 px hairline).
- Motion (`Motion`): hover 0.12 s ease-out, pop = spring(0.25, 0.85), panel = 0.3 s (.16, 1, .3, 1); none with
  Reduce Motion.
- Vibrancy: Glass uses `.sidebar` material behind the sidebar; Ink and Grid are opaque.

## Components
- **Tab** — icon (agent mark / terminal glyph) + title + activity dot; close × on hover; active = `raised`
  card with a hairline (Ink), accent underline (Grid), segment (Glass); inactive tabs have no fill until hovered.
- **Sidebar top** — workspace menu (no fill until hovered), then Search (⌘K hint, opens the palette), Inbox and a
  PROJECTS label; Search moves next to the traffic lights only while the sidebar is hidden.
- **Top bar** — tabs from the left over the full width; on the right only project-wide actions: diff count,
  Open in, Commit ▾ (Changes panel with the message box; Create Pull Request), right panel.
- **Pane header** — on every pane (not only in splits): agent mark, title, working folder, activity; split,
  zoom (splits only), chat ↔ terminal, browser and dock (the only or focused pane), session menu, close.
- **Sidebar row** — project: 18 px color tile with initial/icon, semibold name, branch in mono `text3`,
  amber count badge when sessions wait. Session: 14 px icon, title, trailing activity (working ring in
  accent, amber “input” pill, green done dot); dormant at 45% opacity; hover reveals stop / restart / remove.
  Selected: the workspace color at 13% (`RowBackground`).
- **SectionHeader** — uppercase `micro` label, optional count, trailing tools (sidebar, palette groups).
- **SegmentedTabs** — hover-filled track, selected segment = `raised` thumb with a soft shadow (right panel).
- **ShortcutHint** — key capsule ("esc", "↵", "⌘K") in palettes and footers.
- **Buttons** — icon buttons in three sizes only (`IconButtonStyle.snap`: 18 rows/tabs, 22 panel tools,
  26 window chrome), radius 6; `PrimaryButton` (accent fill, white 12 semibold), `SecondaryButton` (hairline).
- **Chip** — 22 px, radius 6, `hover` fill; used for dock tabs, diff stat, filters.
- **Popover / menu** — short command menus (context menus, + menus, ▾ lists of actions) stay native. Pickers that
  show state use `floatingPanel` (UI/FloatingPanel.swift): `PanelCard` (`raised`, hairline, radius 12, the window's
  shadow), `PanelSectionTitle`, `PanelRow` (icon, title, detail, shortcut, check; 28 tall), `PanelChip`,
  `PanelNav` for ↑↓ ↩; esc or a click outside closes (the click does nothing else). Workspace switcher, Keep Mac
  awake and the top bar's Commit panel use it.
- **Command palette** — 620 wide, radius 14; without a query, grouped (Waiting for you / Sessions / Commands)
  with `SectionHeader`s; footer with key hints and the result count.
- **Tab switcher** — ⌃Tab / ⌃⇧Tab while ⌃ is held: the project's tabs most recent first, each with a picture of
  its work area (taken from Octomux's own window after the tab has been on screen), activity, title and agent;
  release ⌃ or ↵ to open, Esc to cancel.
- **Empty state** — centered: 40 px glyph in `text3`, headline, one line `text2`, buttons row.
- **Start screen** (new chat / empty tab) — one block above the composer: the octopus (`OctoMark`, drawn from the
  app icon), "What should we build in <project>?", a summary line, Waiting for you / Recent cards (rows open the
  session), starter chips (fill the composer, never send). The composer sits at the bottom in a 720 pt column —
  the same column as the chat view's messages and composer, so nothing moves or resizes when the chat starts.
- **Status indicators** — `ActivityIndicator`: working = rotating accent ring; needs input = amber pill;
  done = green dot (unread); error = red dot; restoring = amber arrow. Usage limits in the status bar: 12 px rings.
- **Chat** — the user's messages in a neutral bubble (white 7.5% / black 5%), never the accent.

## Layouts

- The window's chrome is read from the layout (`Core/Layout.swift`, global setting `ui.layout`): sidebar rows and
  sections, the sidebar's bottom row, the status bar's left and right items, the top bar's buttons. Terminal is
  the default and is the window as designed; a change to it changes the default look for everyone, so it needs
  the same review as any redesign. Other layouts and user changes are opt-in.
- A new item in one of those regions is added to `LayoutRegion.items` (and its title), placed in each built-in
  layout, and drawn by the region's switch. Stored layouts that don't mention it get it where the built-in layout
  has it.
- Layouts tile only; nothing floats over a terminal (its Metal surface stops drawing under a SwiftUI layer).
- A feature never belongs to a layout. It ships in three layers: the core (daemon / model, reachable from the CLI and
  the Octomux MCP), building blocks usable anywhere (a palette command, a sidebar section, a right-panel tab, a chip
  in a session header, an Inbox action) registered as layout items so any layout can turn them on, and only then
  layouts, which choose what is primary and the defaults. New items start off in Terminal. A pure visualisation may
  live in one layout only.

### Layout engine
- A layout's window is a JSON tree (`app/Resources/layouts/<layout>.json`, schema 1) that `Core/LayoutTree.swift`
  reads and `UI/Shell.swift` draws — every layout, Terminal included: its tree draws today's window to the pixel
  (checked against the classic window in 13 states), and a switch stays inside one window. `MainView.classicWindow`
  remains as the fallback for a tree that can't be used.
- Nodes: `row` / `column` (children side by side / stacked) and `stack` (one child shows: Home while the window is on
  its Home, else the first other one); each child may have a `size` along its parent's axis: `{"fixed": pt}`,
  `{"min": pt}` or `{"flex": weight}`. Leaves are blocks, optionally with a `variant`; there is no code in a layout,
  only data.
- Blocks and their rules (a tree that breaks one is not used; the layout's built-in tree is, else the classic window):

  | Block | What | Kind | Minimum |
  |---|---|---|---|
  | `agentRail` | sessions by state (Waiting / Working / Done / Idle), project chips, New session | rail (in a row) | 220 |
  | `tasksRail` | the workspace's tasks by state, status filters, the assistant, New task | rail | 240 |
  | `projectTree` | the classic sidebar (its width and resize handle) | rail | 200 |
  | `sidePanel` | the right panel (Files / Changes / Sessions / Tasks), shown with ⌘⌥B | rail | 260 |
  | `taskDetail` | the picked task: state, agents and what they last said, PR, subtasks, next step (⌘⌥B) | rail | 280 |
  | `sideAgent` | the project's agent beside the work area (the layout's "Agent beside the work area") | rail | 280 |
  | `tabStrip` | the classic top bar with tabs | bar (in a column) | — |
  | `breadcrumb` | Home · workspace (Tasks · task), or agent · project · branch, and the project's buttons | bar | — |
  | `aquariumStrip` | the aquarium above the panes (the layout's views switch; not while its tab is open) | bar | 120 |
  | `statusBar` | the status bar (the layout's on/off) | bar | — |
  | `workArea` | the current tab's panes or doc, browser, dock; required | main | 320 |
  | `home` | the window's Home; variants `agents` (greeting, composer, waiting, recent, usage) and `workday` (the day page) | main (also in a stack) | 320 |

  Every block at most once; a stack holds main blocks and containers; `agentRail` and `tasksRail` not together. An
  unknown variant reads as the block's first (a later version's variant shows as today's block).
- How the window moves follows its list: with `agentRail` ⌘1…8 / ⌘9 and ⌘[ ⌘] go through the agents (⌘T Home's
  composer, ⌘0 Home, ⌘W nothing on Home); with `tasksRail` through the tasks (⌘T a new task, ⌘0 the assistant);
  otherwise tabs, as in the classic window. Menu titles follow (Agent 3, Task 3, Tab 3). A rail takes ↑ ↓ ↩ only
  after a click on it or ⌥⌘A (an app-local key monitor that listens only then).
- The terminal views are the classic window's, moved: each terminal area has a slot, and the slot in the window holds
  the shared pane container, so a window rebuilt (another layout, a theme change) never drops or remakes them. A
  container keeps every child in its list and leaves one that is off out by its own `if` (identity by block).
- Performance: the resolved layout is cached per change of the settings; the agents' transcripts are read once for
  every block that shows them (rail, Home, task detail), after the first frame, and only while one is on screen.
  Measured per layout: idle CPU as the classic window (the Aquarium swims at 12 frames a second while you're at
  it, one a second behind other apps or after 30 s without input and no agent changing state: ~0.4–0.8%), +5–30 MB, switches mostly 90–230 ms, no terminal view made by a switch. A terminal area that
  takes the panes draws them on the next turn; the Tasks window selects its assistant just after its first frame;
  the engine's blocks are drawn once off screen a few seconds after launch (no readers, no key monitors), so the
  first switch to a layout doesn't pay for loading them.
- A user's own tree goes in `custom.<layout>.tree`, dragged widths in `custom.<layout>.sizes`; both go over the
  built-in tree, which keeps getting our updates.

### Layouts as files (format v1)
- One file, `.octomux-layout.json`, data only:

  ```json
  {"schema": 1, "name": "Review desk", "author": "Ada", "base": "agents",
   "tree": {"row": [{"block": "agentRail"}, {"column": [{"block": "breadcrumb"},
            {"stack": [{"block": "home", "variant": "workday"}, {"block": "workArea"}]}, {"block": "statusBar"}]}]},
   "settings": {"regions": {"statusRight": [{"id": "usage", "on": false}]}, "statusBar": true, "chat": true},
   "theme": {"id": "ink", "mode": "dark"}, "keys": {"cmd.next-tab": "cmd+shift+]"},
   "preview": "data:image/png;base64,…"}
  ```

  `base` is a built-in layout: what the file doesn't say comes from it, and an older version (or a Mac without the
  saved layout) opens it. `tree` is optional (none: the base's window). `settings` are the layout's region items and
  switches. `theme`, `keys` and `preview` are optional.
- Reading (`Core/LayoutFile.swift`): unknown fields are ignored. Refused, with the reason shown: not JSON, over 2 MB,
  another schema, no name, an unknown base, a tree that breaks the blocks' rules. Left out with a note: a theme this
  Mac doesn't have, a shortcut for an unknown command or that isn't modifiers + one key, a preview that isn't a PNG
  or JPEG in the file (nothing remote).
- Saved layouts live in the global setting `ui.layouts` (`{"<id>": <file without its preview>}`); their pictures
  in `<Octomux home>/layout-previews/<id>.png`. The layout in use is `ui.layout` with `"user": "<id>"` (and its base
  in `layout`); your changes to a saved layout go to `custom["user:<id>"]`, not to its base.
- Settings → Layout → Your layouts: Save Current as New, Import (a sheet: the window drawn from the tree or its
  picture, name, author, base, its blocks, what was left out; its theme and shortcuts only when ticked), Export (your
  theme and shortcuts only when ticked), Duplicate, Delete, Use the Window as Picture. Saved layouts are in the
  View menu under the built-in ones (⌃⌘8, ⌃⌘9 for the first two) and in the status bar's Layout panel.

## Terminal theme
Each preset carries a terminal palette matched to its `surface` color (background = `surface`, so the card
and the terminal are one plane). Applied by writing `$OCTOMUX_HOME/theme.conf` (Ghostty syntax) and loading it
after the user's `terminal.conf`, unless “Use theme colors in terminal” is off.
Ink dark: bg `#1B1B1F`, fg `#DCDCE0`, cursor `#EB8A5E`, selection `#3A3A42`; ANSI palette in `Theme.swift`.
