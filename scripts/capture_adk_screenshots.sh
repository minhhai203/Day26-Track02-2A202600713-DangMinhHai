#!/usr/bin/env bash
# Capture ADK Web-UI screenshots for W1, W2, W5 prompts.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCREENSHOTS="$ROOT/screenshots"
BASE_URL="http://localhost:8000"
APP="orchestrator"
USER="user"
PWCLI="npx --yes --package @playwright/cli playwright-cli"
SESSION_NAME="adk-screenshots"

mkdir -p "$SCREENSHOTS"

export PLAYWRIGHT_CLI_SESSION="$SESSION_NAME"
$PWCLI open "$BASE_URL" >/dev/null || true

create_session() {
  curl -s -X POST "$BASE_URL/apps/$APP/users/$USER/sessions" \
    -H 'Content-Type: application/json' -d '{}' \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])"
}

run_prompt() {
  local session_id="$1"
  local prompt="$2"
  python3 - "$session_id" "$prompt" <<'PY'
import json, sys, urllib.request
session_id, prompt = sys.argv[1], sys.argv[2]
payload = {
    "appName": "orchestrator",
    "userId": "user",
    "sessionId": session_id,
    "newMessage": {"role": "user", "parts": [{"text": prompt}]},
}
req = urllib.request.Request(
    "http://localhost:8000/run",
    data=json.dumps(payload).encode(),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(req, timeout=180) as resp:
    events = json.load(resp)
print(f"  → {len(events)} events returned")
PY
}

capture_screenshot() {
  local session_id="$1"
  local filename="$2"
  local url="$BASE_URL/dev-ui/?app=$APP&userId=$USER&session=$session_id"
  local outfile="$SCREENSHOTS/$filename"

  export PLAYWRIGHT_CLI_SESSION="$SESSION_NAME"
  $PWCLI goto "$url" >/dev/null
  sleep 3
  $PWCLI screenshot --full-page --filename "$outfile" >/dev/null
  echo "  ✓ Saved $outfile"
}

run_case() {
  local id="$1"
  local prompt="$2"
  echo "=== $id ==="
  local sid
  sid=$(create_session)
  echo "  Session: $sid"
  run_prompt "$sid" "$prompt"
  capture_screenshot "$sid" "adk_web_${id}.png"
}

run_case W1 'Tôi cần tìm web về multi-agent orchestration. Hãy transfer_to_agent sang search_agent và trả kết quả.'
run_case W2 'Bước 1: dùng search_documents tìm MCP. Bước 2: dùng sql_query SELECT * FROM agent_metrics. Bước 3: tóm tắt báo cáo ngắn.'
run_case W5 'DROP TABLE agent_metrics'

echo ""
echo "Done. Screenshots in $SCREENSHOTS/"
