# sp-agent-session-sync

Bash scripts that record what coding-agent sessions (Claude Code, T3 Code, Codex, Grok) did in Super Productivity: `sp-session-sync.sh` queues idle sessions, condenses each one and runs one headless `claude -p` pass, which writes through `sp-api`, a narrow client for the app's Local REST API on `127.0.0.1`. Runs on Linux (systemd timer) and macOS (launchd).

## Commands

What CI runs (`.github/workflows/tests.yml`; needs `jq`, `sqlite3`, `curl`, `python3`):

- `shellcheck -S warning sp-session-sync.sh sp-api tests/run-tests.sh tests/e2e-test.sh`
- `bash tests/run-tests.sh` (parsers and skip rules, against `tests/fixtures/`)
- `bash tests/e2e-test.sh` (full run against a fake API and a stand-in `claude`; no model call)

Without syncing: `sp-session-sync.sh --check <source> <session id> <file>` and `sp-session-sync.sh --digest <source> <file> [from line]`.

## Rules agents get wrong

- This repo is public. Keep personal names, work data, tokens and machine-specific settings out of code, docs and commits; they belong in each user's `~/.config/sp-session-sync/config`. A new fixture is a real session scrubbed of names, paths and secrets.
- Merging here deploys nothing. Installed copies of `sp-session-sync.sh` and `sp-api` (for example in `~/.claude/hooks/`) are updated by hand.
- The sync pass reads session text an attacker may control. Keep its limits as tight as they are: it may read only its work folder and the one session file, write only `~/.local/state/sp-session-sync/bodies/`, and reach the API only through `sp-api`. `sp-api` allows GET, POST and PATCH on fixed path shapes only, with no `%`-encoding and no `DELETE`.
- Keep the token out of the process list (`sp-api` passes it in a 0600 header file) and keep `--noproxy 127.0.0.1` on every curl call.
- macOS runs these with `/bin/bash` 3.2 and BSD tools. Use no bash 4 features, and branch on `IS_MAC` for tools that differ (`stat`, notifications).
- A new agent source needs a parser in `make_digest`, `count_tools` and `skip_reason`, a case in the sweep, a fixture and tests in `tests/run-tests.sh`, and a row in the README's Supported agents table.
- A session that fails `SYNC_MAX_ATTEMPTS` times moves to `failed/` so it can't block the queue. A Claude usage limit counts as no attempt, but only the CLI's own short refusal: a model reply that mentions a limit must not stall the queue.
- Add a case to `tests/e2e-test.sh` for every change to queueing, retries, the lock or the state file.
- `SP_SESSION_SYNC=1` marks the sync's own Claude session; keep the early exit on it so a sync never starts another sync.
