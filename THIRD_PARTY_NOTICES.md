# Third-party notices

Octomux ships with, or is built from, the following open-source software. Each is used under its own license;
the full texts are in the linked repositories (and, for the bundled ones, inside the app).

## Bundled in the app

| Component | Used for | License |
|---|---|---|
| [Ghostty](https://github.com/ghostty-org/ghostty) (libghostty, terminal themes) | Terminal rendering and emulation | MIT |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | Updates | MIT (with notices for bundled code, see its LICENSE) |
| [CodeMirror 6](https://github.com/codemirror/dev) and language packages | Code viewer (`app/Resources/editor/editor.js`) | MIT |
| [Lezer](https://github.com/lezer-parser) | Syntax parsing in the code viewer | MIT |
| [marked](https://github.com/markedjs/marked) | Markdown preview | MIT |
| [Simple Icons](https://simpleicons.org) | Claude, OpenAI and Gemini marks (`UI/BrandIcons.swift`) | CC0-1.0; the marks are trademarks of their owners |

## Rust crates (the `octomux` daemon and CLI)

[anyhow](https://github.com/dtolnay/anyhow), [clap](https://github.com/clap-rs/clap),
[libc](https://github.com/rust-lang/libc), [portable-pty](https://github.com/wez/wezterm/tree/main/pty),
[rusqlite](https://github.com/rusqlite/rusqlite) (with bundled SQLite, public domain),
[serde](https://github.com/serde-rs/serde), [serde_json](https://github.com/serde-rs/json),
[signal-hook](https://github.com/vorner/signal-hook), [uuid](https://github.com/uuid-rs/uuid),
[vt100](https://github.com/doy/vt100-rust) and their dependencies: MIT and/or Apache-2.0.
Run `cargo tree` in `core/` for the full list.
