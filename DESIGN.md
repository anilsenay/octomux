# ADE design system

Source of truth in code: `app/Sources/ADE/UI/Theme.swift` (tokens + presets) and
`app/Sources/ADE/UI/Components.swift` (shared components). Directions explored: `design/directions/`
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

| style | size / weight | use |
|---|---|---|
| `title` | 20 / bold | settings page title |
| `headline` | 13 / semibold | section titles, project names |
| `body` | 13 / regular | rows, menus |
| `small` | 12 / medium | tabs, buttons |
| `caption` | 11 / medium | status bar, badges |
| `label` | 11 / semibold (Grid: 10.5 mono uppercase, +8% tracking) | section labels |
| `mono` | 12 / regular | branch, diff stats, commands |

## Spacing, radius, elevation
- Spacing scale: 2, 4, 6, 8, 10, 12, 16, 20, 24, 32.
- Rows: 30 px (Grid 24), radius 7 (Grid 2, Glass 8). Tabs: 28 px pills (Grid: 36 px underline tabs;
  Glass: segmented control). Top bar 46 px, status bar 30 px (Grid 36 / 24).
- Cards: radius 10 (Glass 12, Grid 0), 1 px `border`, inset 8 px from the window edge, 8 px gap
  between panes.
- Shadows only on floating things: active pill tab (0 1 2 black 18%), popovers/menus (system),
  Glass sidebar.
- Vibrancy: Glass uses `.sidebar` material behind the sidebar; Ink and Grid are opaque (more cohesive with
  the terminal, cheaper to render).

## Components
- **Tab** — icon (agent mark / terminal glyph) + title + activity dot; close × on hover; active = `raised`
  pill with shadow (Ink), accent underline (Grid), segment (Glass).
- **Sidebar row** — project: 18 px color tile with initial/icon, semibold name, branch in mono `text3`,
  amber count badge when sessions wait. Session: 14 px icon, title, trailing activity (working ring in
  accent, amber “input” pill, green done dot); dormant at 45% opacity; hover reveals stop / restart / remove.
- **Chip** — 22 px, radius 6, `hover` fill; used for dock tabs, diff stat, filters.
- **Button** — `ChromeButton` (icon, 26 px square, hover fill); `PrimaryButton` (accent fill, white text);
  `SecondaryButton` (hairline border).
- **Popover / menu** — native menus; custom popovers use `raised` + system shadow, radius 10.
- **Empty state** — centered: 40 px glyph in `text3`, headline, one line `text2`, buttons row.
- **Status indicators** — `ActivityIndicator`: working = rotating accent ring; needs input = amber pill;
  done = green dot (unread); error = red dot; restoring = amber arrow.

## Terminal theme
Each preset carries a terminal palette matched to its `surface` color (background = `surface`, so the card
and the terminal are one plane). Applied by writing `$ADE_HOME/theme.conf` (Ghostty syntax) and loading it
after the user's `terminal.conf`, unless “Use theme colors in terminal” is off.
Ink dark: bg `#1B1B1F`, fg `#DCDCE0`, cursor `#EB8A5E`, selection `#3A3A42`; ANSI palette in `Theme.swift`.
