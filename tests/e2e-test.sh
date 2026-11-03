#!/bin/bash
# End-to-end run of the worker in a throwaway HOME, against a fake Super Productivity
# Local REST API and a stand-in `claude` that makes one PATCH through sp-api. No real app,
# no model call. Checks: the sweep queues a session, the sync pass gets a backup and the
# task index, sp-api sends the token and the body, state is saved, a failed pass is
# retried and then set aside (and the sweep leaves it there), a bad token stops the sync
# before any model call, a Claude usage limit counts no attempt, and a successful sync
# clears a stale set-aside copy.
# Needs bash, jq, curl and python3.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
repo="$here/.."
tmp=$(mktemp -d)
port=$((20000 + RANDOM % 20000))
cleanup() { [ -n "${server:-}" ] && kill "$server" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config" XDG_RUNTIME_DIR="$tmp/run"
mkdir -p "$HOME/.claude/projects/app" "$XDG_CONFIG_HOME/sp-session-sync" "$XDG_RUNTIME_DIR" "$tmp/bin"
fail=0
expect() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', expected '$3'"; fail=1; fi; }

# Fake API: checks the token, answers the calls the sync makes, records writes.
echo "test-token-123" > "$tmp/token"
cat > "$tmp/server.py" <<'EOF'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
port, log = int(sys.argv[1]), sys.argv[2]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, body):
        b = json.dumps(body).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def authed(self):
        if self.headers.get("Authorization") != "Bearer test-token-123":
            self.send(401, {"ok": False, "error": {"code": "UNAUTHORIZED"}}); return False
        return True
    def do_GET(self):
        if self.path == "/health": return self.send(200, {"ok": True, "data": {"server": "up", "rendererReady": True}})
        if not self.authed(): return
        if self.path.startswith("/tasks"): return self.send(200, {"ok": True, "data": [{"id": "t1", "title": "Uploader retries", "isDone": False, "notes": ""}]})
        if self.path == "/projects": return self.send(200, {"ok": True, "data": [{"id": "INBOX_PROJECT", "title": "Inbox"}]})
        self.send(404, {"ok": False})
    def do_PATCH(self):
        if not self.authed(): return
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        open(log, "a").write(f"PATCH {self.path} {body}\n")
        self.send(200, {"ok": True, "data": {"id": "t1"}})
HTTPServer(("127.0.0.1", port), H).serve_forever()
EOF
python3 "$tmp/server.py" "$port" "$tmp/writes.log" & server=$!
for _ in $(seq 1 50); do curl -s --noproxy 127.0.0.1 "http://127.0.0.1:$port/health" >/dev/null && break; sleep 0.1; done

# Stand-in for `claude -p`: checks it was handed a backup and index, writes a body into the
# bodies folder, PATCHes through sp-api and reports done (or fails when asked to).
# Stand-in for notify-send, so the tests show no real desktop notifications.
printf '#!/bin/bash\necho "$2" >> "%s/notifications.log"\n' "$tmp" > "$tmp/bin/notify-send"
chmod +x "$tmp/bin/notify-send"

cat > "$tmp/bin/claude" <<'EOF'
#!/bin/bash
prompt="$2"
[ -n "${FAKE_CLAUDE_FAIL:-}" ] && { echo "Updated the usage limit task, could not finish."; echo "SYNC_RESULT: incomplete"; exit 0; }
[ -n "${FAKE_CLAUDE_LIMIT:-}" ] && { echo "You've hit your 5-hour limit · resets 8:30am (America/Jamaica)"; exit 1; }
backup=$(grep -o '[^ ]*-tasks-before\.json' <<<"$prompt" | head -1)
jq -e '.ok' "$backup" >/dev/null || { echo "no backup"; exit 1; }
bodies="$HOME/.local/state/sp-session-sync/bodies"
echo '{"notes":"2026-11-01 COMPLETED: retries added"}' > "$bodies/patch.json"
sp_api=$(grep -o '[^ ]*/sp-api' <<<"$prompt" | head -1)
"$sp_api" PATCH /tasks/t1 "$bodies/patch.json" >/dev/null || { echo "sp-api failed"; exit 1; }
printf 'Updated 1 task.\nSYNC_RESULT: done\n'
EOF
chmod +x "$tmp/bin/claude"
export PATH="$tmp/bin:$PATH"

printf 'SP_PORT=%s\nSP_TOKEN_FILE=%s\nSYNC_MAX_ATTEMPTS=2\n' "$port" "$tmp/token" > "$XDG_CONFIG_HOME/sp-session-sync/config"
session="$HOME/.claude/projects/app/aaaaaaaa-0000-4000-8000-000000000001.jsonl"
cp "$here/fixtures/claude-cli.jsonl" "$session"
touch -d '-30 minutes' "$session"   # idle long enough for the sweep
state="$HOME/.local/state/sp-session-sync"

# 1. A normal sync.
bash "$repo/sp-session-sync.sh" --sweep
expect "the API saw one PATCH with the body" "$(cat "$tmp/writes.log" 2>/dev/null)" 'PATCH /tasks/t1 {"notes":"2026-11-01 COMPLETED: retries added"}'
expect "state records all 5 lines as synced" "$(cut -d' ' -f1 "$state/state/aaaaaaaa-0000-4000-8000-000000000001.lines")" "5"
expect "the queue is empty" "$(ls "$state/queue" | wc -l | tr -d ' ')" "0"

# 2. Nothing new: the next sweep queues nothing and makes no call.
: > "$tmp/writes.log"
bash "$repo/sp-session-sync.sh" --sweep
expect "an unchanged session is not synced again" "$(cat "$tmp/writes.log")" ""

# 3. A body outside the bodies folder, or a symlink, is refused.
echo '{}' > "$tmp/outside.json"
SP_PORT=$port SP_TOKEN_FILE="$tmp/token" "$repo/sp-api" PATCH /tasks/t1 "$tmp/outside.json" >/dev/null 2>&1
expect "sp-api refuses a body outside the bodies folder" "$?" "2"
ln -s "$tmp/outside.json" "$state/bodies/link.json"
SP_PORT=$port SP_TOKEN_FILE="$tmp/token" "$repo/sp-api" PATCH /tasks/t1 "$state/bodies/link.json" >/dev/null 2>&1
expect "sp-api refuses a symlinked body" "$?" "2"
SP_PORT=$port SP_TOKEN_FILE="$tmp/token" "$repo/sp-api" DELETE /tasks/t1 >/dev/null 2>&1
expect "sp-api refuses DELETE" "$?" "2"
for bad in "GET /tasks/t1%2Ftime" "GET /tasks/t1/time" "PATCH /tasks/t1?x=1" "POST /tasks/t1/archive" "GET /status" "PATCH /projects/p1"; do
  # shellcheck disable=SC2086
  SP_PORT=$port SP_TOKEN_FILE="$tmp/token" "$repo/sp-api" $bad >/dev/null 2>&1
  expect "sp-api refuses $bad" "$?" "2"
done
SP_PORT=$port SP_TOKEN_FILE="$tmp/token" "$repo/sp-api" GET /tasks extra-arg more-args >/dev/null 2>&1
expect "sp-api refuses extra arguments" "$?" "2"
SP_PORT=$port SP_TOKEN_FILE="$tmp/token" "$repo/sp-api" GET '/tasks?source=all&includeDone=true' >/dev/null 2>&1
expect "sp-api allows listing all tasks" "$?" "0"

# 4. A failing pass is retried, then set aside after SYNC_MAX_ATTEMPTS (2 here).
echo '{"type":"user","entrypoint":"cli","message":{"role":"user","content":"and add a test"}}' >> "$session"
echo '{"type":"assistant","entrypoint":"cli","message":{"role":"assistant","content":[{"type":"text","text":"Added."},{"type":"tool_use","id":"t2","name":"Edit","input":{}}]}}' >> "$session"
touch -d '-30 minutes' "$session"
FAKE_CLAUDE_FAIL=1 bash "$repo/sp-session-sync.sh" --sweep
expect "after one failure the session stays queued with 1 attempt" "$(jq -r .attempts "$state/queue/aaaaaaaa-0000-4000-8000-000000000001.json" 2>/dev/null)" "1"
FAKE_CLAUDE_FAIL=1 bash "$repo/sp-session-sync.sh" --sweep
expect "after the second failure it is set aside" "$(ls "$state/failed")" "aaaaaaaa-0000-4000-8000-000000000001.json"
FAKE_CLAUDE_FAIL=1 bash "$repo/sp-session-sync.sh" --sweep
expect "the sweep does not queue a set-aside session again" "$(ls "$state/queue" | wc -l | tr -d ' ')" "0"

# 5. A wrong token: no sync pass at all, the session stays queued.
expect "a set-aside session is stored with a fresh attempt count" "$(jq -r .attempts "$state/failed/aaaaaaaa-0000-4000-8000-000000000001.json")" "0"
mv "$state/failed/aaaaaaaa-0000-4000-8000-000000000001.json" "$state/queue/"
echo "wrong" > "$tmp/token"
: > "$tmp/writes.log"
bash "$repo/sp-session-sync.sh" --sweep
expect "a wrong token makes no write" "$(cat "$tmp/writes.log")" ""
expect "and leaves the session queued" "$(ls "$state/queue")" "aaaaaaaa-0000-4000-8000-000000000001.json"
expect "and says why in the log" "$(grep -c 'could not read tasks' "$HOME/.local/state/sp-session-sync-log/sync.log")" "1"

# 6. A Claude usage limit: no attempt counted, the session stays queued, no failure.
echo "test-token-123" > "$tmp/token"
FAKE_CLAUDE_LIMIT=1 bash "$repo/sp-session-sync.sh" --sweep
expect "a usage limit counts no attempt" "$(jq -r .attempts "$state/queue/aaaaaaaa-0000-4000-8000-000000000001.json" 2>/dev/null)" "0"
expect "and nothing is set aside" "$(ls "$state/failed" | wc -l | tr -d ' ')" "0"
expect "and the log says so" "$(grep -c 'Claude usage limit reached' "$HOME/.local/state/sp-session-sync-log/sync.log")" "1"
FAKE_CLAUDE_LIMIT=1 bash "$repo/sp-session-sync.sh" --sweep
expect "a second limit pass still counts no attempt" "$(jq -r .attempts "$state/queue/aaaaaaaa-0000-4000-8000-000000000001.json" 2>/dev/null)" "0"
expect "and notifies only once" "$(grep -c 'usage limit' "$tmp/notifications.log")" "1"
expect "and leaves no digest or backup behind" "$(ls "$state/done" | grep -c -- '-7')" "0"

# 7. A set-aside session with new work is queued again.
jq '.attempts = 0' "$state/queue/aaaaaaaa-0000-4000-8000-000000000001.json" > "$state/failed/aaaaaaaa-0000-4000-8000-000000000001.json"
rm "$state/queue/aaaaaaaa-0000-4000-8000-000000000001.json"
touch -d '-1 hour' "$state/failed/aaaaaaaa-0000-4000-8000-000000000001.json"
FAKE_CLAUDE_LIMIT=1 bash "$repo/sp-session-sync.sh" --sweep
expect "a set-aside session that grew since is queued again" "$(ls "$state/queue")" "aaaaaaaa-0000-4000-8000-000000000001.json"

# 8. A session queued again while a stale copy sits in failed/: syncing clears the copy.
echo '{"stale":true}' > "$state/failed/aaaaaaaa-0000-4000-8000-000000000001.json"
: > "$tmp/writes.log"
bash "$repo/sp-session-sync.sh" --sweep
expect "the queued session syncs" "$(grep -c "^PATCH" "$tmp/writes.log")" "1"
expect "and its stale set-aside copy is removed" "$(ls "$state/failed" | wc -l | tr -d ' ')" "0"

[ "$fail" -eq 0 ] && echo "all end-to-end tests passed" || { echo "--- log ---"; cat "$HOME/.local/state/sp-session-sync-log/sync.log"; exit 1; }
