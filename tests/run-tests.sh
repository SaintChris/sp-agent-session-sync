#!/bin/bash
# Checks the session parsers and skip rules against the sample sessions in fixtures/.
# Nothing is synced: only the --digest and --check test modes run, in a throwaway HOME.
# Needs bash, jq and sqlite3.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
sync="$here/../sp-session-sync.sh"
fx="$here/fixtures"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp" SP_SYNC_T3_DB="$tmp/t3.sqlite"
fail=0

expect() { # name actual expected
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1"; diff <(echo "$3") <(echo "$2") | sed 's/^/     /'; fail=1; fi
}

# A minimal T3 Code database: one thread you started, one an agent started.
sqlite3 "$SP_SYNC_T3_DB" "
  create table orchestration_v2_projection_threads (thread_id text, payload_json text);
  create table orchestration_v2_projection_provider_threads (thread_id text, payload_json text);
  insert into orchestration_v2_projection_threads values ('t-user', '{\"createdBy\":\"user\"}'), ('t-agent', '{\"createdBy\":\"agent\"}');
  insert into orchestration_v2_projection_provider_threads values
    ('t-user', '{\"nativeThreadRef\":{\"nativeId\":\"11111111-0000-4000-8000-000000000001\"}}'),
    ('t-agent', '{\"nativeThreadRef\":{\"nativeId\":\"22222222-0000-4000-8000-000000000002\"}}');"

check() { bash "$sync" --check "$@"; }
digest() { bash "$sync" --digest "$@"; }

expect "claude: terminal session syncs" "$(check claude aaaaaaaa-0000-4000-8000-000000000001 "$fx/claude-cli.jsonl")" "would sync"
expect "claude: T3 thread you started syncs" "$(check claude 11111111-0000-4000-8000-000000000001 "$fx/claude-t3.jsonl")" "would sync"
expect "claude: T3 session with no thread you started is skipped" \
  "$(check claude 33333333-0000-4000-8000-000000000003 "$fx/claude-t3.jsonl")" \
  "sdk-ts session not from a T3 thread you started (a subagent, delegated task or other SDK app)"
expect "claude: other SDK runs are skipped" "$(check claude aaaaaaaa-0000-4000-8000-000000000001 "$fx/claude-sdk-py.jsonl")" "sdk-py session, not interactive"
expect "codex: interactive session syncs" "$(check codex cccccccc-0000-4000-8000-000000000001 "$fx/codex.jsonl")" "would sync"
expect "codex: codex exec run is skipped" "$(check codex cccccccc-0000-4000-8000-000000000001 "$fx/codex-exec.jsonl")" "codex exec run, not interactive"
expect "codex: thread an agent started in T3 is skipped" "$(check codex 22222222-0000-4000-8000-000000000002 "$fx/codex.jsonl")" "T3 thread started by an agent"
expect "grok: session syncs" "$(check grok gggggggg-0000-4000-8000-000000000001 "$fx/grok.jsonl")" "would sync"

echo "garbage" > "$tmp/broken.sqlite"
expect "an unreadable T3 database can't hold up the queue (treated as unknown)" \
  "$(SP_SYNC_T3_DB="$tmp/broken.sqlite" bash "$sync" --check codex cccccccc-0000-4000-8000-000000000001 "$fx/codex.jsonl")" \
  "would sync"

# Hold a write lock on the database for a while: a busy T3 database means retry later.
(echo "begin exclusive;"; sleep 9; echo "commit;") | sqlite3 "$SP_SYNC_T3_DB" & locker=$!
sleep 1
expect "a busy T3 database means retry later (takes a few seconds)" \
  "$(check claude 11111111-0000-4000-8000-000000000001 "$fx/claude-t3.jsonl")" \
  "RETRY: T3 Code's database is busy"
wait "$locker"

expect "claude digest: typed prompts and visible replies only" "$(digest claude "$fx/claude-cli.jsonl")" "## USER
add a retry to the uploader
## CLAUDE
I'll add a retry with backoff.
## CLAUDE
Done: uploads retry 3 times."

expect "codex digest: skips the environment context" "$(digest codex "$fx/codex.jsonl")" "## USER
fix the failing parser test
## CODEX
Fixed an off-by-one; all tests pass."

expect "grok digest: typed prompts (even an unclosed tag), no generated context" "$(digest grok "$fx/grok.jsonl")" "## USER
rename the config loader
## GROK
Renaming it now.
## GROK
Renamed and updated 4 imports.
## USER
now add a test"

expect "digest from a line offset only covers new lines" "$(digest claude "$fx/claude-cli.jsonl" 4)" "## CLAUDE
Done: uploads retry 3 times."

[ "$fail" -eq 0 ] && echo "all tests passed" || { echo "some tests failed"; exit 1; }
