# sp-agent-session-sync

Keep [Super Productivity](https://github.com/super-productivity/super-productivity) up to date with the work your coding agents do, without asking them to.

When a coding-agent session ends or goes idle, this reads what was asked and what the agent answered. A short, headless Claude Code pass then updates your tasks through Super Productivity's Local REST API:

- **Updates** the related tasks with a dated note (COMPLETED / PARTIAL / IN PROGRESS / NOT STARTED).
- **Completes** a task when the session shows it was finished and verified.
- **Adds** follow-ups that no existing task covers.

It searches before it creates anything, never deletes, and never invents deadlines or estimates.

Super Productivity's own [Agent Task Capture (MCP)](https://github.com/super-productivity/super-productivity/blob/master/docs/wiki/3.01-API.md) lets an agent add tasks when you ask it to. This works the other way round: it records what happened after the fact, for every agent you use, so your task list stays current even when you never mention it.

## Supported agents

| Agent | Where its sessions are read from | What is synced |
| --- | --- | --- |
| Claude Code | `~/.claude/projects/*/*.jsonl` | Terminal sessions |
| [T3 Code](https://github.com/pingdotgg/t3code) (Claude threads) | same files, entrypoint `sdk-ts` | Threads you start. Subagents, `/code-review` runs and delegated tasks are skipped: they belong to the thread that started them |
| Codex CLI (terminal or T3 Code) | `${CODEX_HOME:-~/.codex}/sessions/**/rollout-*.jsonl` | Interactive sessions; `codex exec` runs are skipped |
| Grok CLI | `~/.grok/sessions/<folder>/<session>/chat_history.jsonl` | The prompts you typed, not generated context |

A source is on when its session folder exists. Turn one off with a line in `~/.config/sp-session-sync/sources`:

```text
grok off
```

Other SDK runs (for example automated reviews started with the Python or CLI SDK) are skipped, so only sessions you drove count.

Cursor CLI, Gemini CLI, OpenCode and Crush are not supported yet. Each needs a parser in `make_digest`, `count_tools`, `skip_reason` and the sweep; pull requests with a real (scrubbed) sample session are welcome.

## How it works

1. **Queue.** Claude Code's `SessionEnd` hook queues a session the moment it ends. Every 30 minutes a sweep (systemd timer or launchd) also queues any session from any enabled source that changed in the last 24 hours, has been idle for 20 minutes and has lines not synced yet. That catches agents without an exit hook, background sessions, and sessions cut off by a reboot.
2. **Condense.** A worker takes one session at a time and keeps only the part not synced before. It turns that into a short digest of your prompts and the agent's visible replies; the full session file stays available as evidence.
3. **Update.** It backs up all tasks to a JSON file, then runs `claude -p` with Sonnet. That run can read only its own work folder and the one session file, write only request bodies, and call the API only through `sp-api`, a narrow client limited to reading tasks and projects, creating a task and updating a task on `127.0.0.1` (no `DELETE`). The run must end with `SYNC_RESULT: done`. Otherwise the session stays queued and is retried on the next exit or sweep. After `SYNC_MAX_ATTEMPTS` failures it moves to `failed/`, so one stuck session never blocks the others. The sweep leaves it there; move it back to `queue/` to retry, and a later successful sync removes any leftover copy. A Claude usage limit ("You've hit your 5-hour limit") counts as no attempt: the whole queue waits for the next exit or sweep, with one notification every 4 hours at most.

Each sync costs one Sonnet call per idle stretch of new work. Sweeps that find nothing make no model call. A session with no prompts, or with one prompt and no tool calls, is skipped without a model call.

Agents sometimes rewrite their session files (compaction). The state records a checksum of the last synced line, so a rewritten file is read again from the start, and the model skips updates the task notes already contain.

## Requirements

- Super Productivity **desktop**, with the Local REST API turned on (**Settings → Misc**). It must be running when a sync happens; queued sessions wait until it is.
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`claude`) for the sync pass. This runs on your Claude subscription or API key, whichever `claude` uses.
- `bash`, `jq` and `curl`. `sqlite3` is needed only for T3 Code.
- Linux (systemd) or macOS (launchd).

## Install

```bash
git clone https://github.com/SaintChris/sp-agent-session-sync ~/.local/share/sp-session-sync
```

**1. Settings (optional).** The defaults suit a single default profile on port 3876. For anything else, create `~/.config/sp-session-sync/config`:

```bash
SP_PORT=3876          # Local REST API port
SP_TOKEN_FILE=""      # empty = the default profile's local-rest-api-token
SYNC_MODEL=sonnet     # model for the sync pass
SYNC_TIMEOUT=1800     # seconds before a sync pass is stopped
SYNC_MAX_ATTEMPTS=5   # failed passes before a session is set aside
SYNC_TZ=""            # time zone for dates in notes, e.g. Europe/Berlin (empty = the system's)
SYNC_LOG=""           # log file (empty = the default below)
SYNC_PROMPT_EXTRA=""  # your own extra instructions for the sync pass
```

`SP_TOKEN_FILE` lets you point at another profile, for example one started with `--user-data-dir=... --rest-api-port=...`.

**2. Claude Code exit hook.** Add this to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionEnd": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "bash \"$HOME/.local/share/sp-session-sync/sp-session-sync.sh\"", "timeout": 15 }
        ]
      }
    ]
  }
}
```

**3. The 30-minute sweep.**

Linux:

```bash
mkdir -p ~/.config/systemd/user
cp ~/.local/share/sp-session-sync/systemd/sp-session-sync.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now sp-session-sync.timer
```

macOS: copy `launchd/io.github.saintchris.sp-session-sync.plist` to `~/Library/LaunchAgents/`, replace `YOU` with your user name, then:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/io.github.saintchris.sp-session-sync.plist
```

Check that `PATH` in the service or plist reaches `claude`, `jq`, `curl` and `sqlite3`.

**4. Check it.** Start a sweep by hand (`systemctl --user start sp-session-sync.service` on Linux), then read the log:

- Linux: `~/.local/state/sp-session-sync-log/sync.log`
- macOS: `~/Library/Logs/sp-session-sync.log`

Each sync writes its digest, task backup and result to `~/.local/state/sp-session-sync/done/`, which is pruned after 14 days.

## Try it without syncing

```bash
sp-session-sync.sh --check claude <session id> <session file>   # would it sync, or why not
sp-session-sync.sh --digest grok <session file> [from line]      # the digest it would send
bash tests/run-tests.sh                                          # parser and skip-rule tests
bash tests/e2e-test.sh                                           # full run against a fake API, no model call
```

## Safety

- The session files are passed to the model as data, with an instruction to ignore requests inside them. Its tools stop it from running commands, reaching the network, deleting anything, or reading files outside the sync's own folder and the session being synced. The session itself may contain anything the agent printed, so the prompt forbids copying secrets into notes.
- The model can write only to `~/.local/state/sp-session-sync/bodies/`, not to the queue, the state or the lock, so a prompt hidden in a session can't redirect what gets synced next.
- `sp-api` sends only plain files from that folder (no symlinks). It keeps the API token out of the process list (header file, mode 0600) and bypasses proxies for `127.0.0.1`, as the [Local REST API docs](https://github.com/super-productivity/super-productivity/blob/master/docs/wiki/3.01-API.md) recommend.
- No sync runs without a fresh backup of every task and a valid answer from the API; a wrong token stops it before any model call.
- `sp-api` takes exactly a method, a path and an optional body, and allows only fixed path shapes (no `%`-encoding).
- The pass is limited by Claude Code's permission rules, not by an OS sandbox. If you want a hard boundary, run the worker inside one (for example bubblewrap with a read-only home except `~/.local/state/sp-session-sync/bodies`).
- A sync never runs inside another sync (`SP_SESSION_SYNC=1`), and one lock ensures that only one worker runs at a time.

## Limits

- **T3 delegation:** T3 Code keeps no record linking a thread an agent started to its Codex or Grok session. A Codex task delegated inside T3 therefore looks like one you ran. The sync skips updates the notes already contain, which keeps this from doubling up.
- **Codex:** the Codex parser follows the rollout format and is tested on samples, not yet on a long real session.
- **Time zone:** dates use the computer's local time zone.

## License

MIT
