# Contributing to Octomux

Thanks for helping. Octomux is a small project, so a little coordination goes a long way.

## Report a bug

Use the **Bug report** template. Search open and closed issues first. The most useful reports are short:

- what happened, and what you expected
- the shortest way to make it happen again
- your Octomux version (Octomux → About), macOS version, and the agent involved
- if relevant, the end of `~/Library/Application Support/Octomux/logs/daemon.log`

## Suggest a feature or a new agent

Open a **Feature request**, or an **Agent request** if you want deeper support (status, resume, usage) for a CLI
agent. Questions and open-ended ideas fit better in [Discussions](https://github.com/anilsenay/octomux/discussions).

## Pull requests

- For anything beyond a small fix, open an issue first so we can agree on the approach before you spend time on it.
- Keep a PR to one change, and describe how you tested it. UI changes: include a screenshot.
- To use your build day to day, build **Octomux Dev** (`tools/build-app.sh release dev`): it runs next to your
  installed Octomux with its own data, so a bug in your branch can't touch your real sessions.
- `cd core && cargo test` and `cd app && swift test` should pass. [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)
  explains the build, the debug harness and the UI fixture (fake agents, so you never test against your real
  sessions).
- Agent-written code is fine, as long as you have read it, run it, and can answer questions about it.
  [AGENTS.md](AGENTS.md) has the notes for coding agents.

By contributing you agree that your work is released under the project's [license](LICENSE).
