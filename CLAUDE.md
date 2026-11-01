# shiibar-gh

macOS menu bar app that shows the GitHub pull requests you are involved in, what needs your action, and what happened, per scope (organization / personal / public). Read-only against GitHub.

## Source of truth

- **Behavior spec**: `docs/DESIGN.md`. Japanese. It states the agreed behavior in present tense.
- **Visual spec**: `docs/design/` (one HTML board per screen). The boards are the reference for layout, labels and colors.
- If the spec is ambiguous, contradictory, or wrong: **stop and report** the issue in your final summary. Do not invent behavior or silently deviate.

## Rules

- Language: **Japanese is allowed ONLY in `docs/`**. Source code, comments, test names, string literals, log messages and commit messages MUST be English. UI text is English only, using GitHub's own terms (see the overview and scope section of DESIGN.md).
- Never hardcode machine-specific absolute paths. Tests must never touch machine state outside their sandbox: no real Keychain, no network, no real state directory or home.
- Never write to GitHub (no read-state sync, no comments, no reviews). DESIGN.md lists this as out of scope.
- Architecture (see the architecture part of the implementation section of DESIGN.md): a Rust daemon owns GitHub polling, local state and the Keychain tokens, and talks NDJSON over a Unix socket; the Rust CLI and the Swift app are both clients of that socket. The app owns the daemon's lifecycle (no launchd). Only the daemon touches the Keychain.
- The CLI reads tokens from stdin, never from arguments.

## CLI

`shiibar-gh` exposes every popover and settings operation (see the CLI part of the implementation section of DESIGN.md). Use it from Bash; `--help` and `--json` are enough. Examples:

```sh
shiibar-gh list --needs-action --json
shiibar-gh done <row>
shiibar-gh snooze owner/repo#123
shiibar-gh config get <key>
```
