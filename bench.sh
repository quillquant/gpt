#!/usr/bin/env bash
# Smoke tests + load/chat benchmark for the local control panel.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="${BASE_URL:-http://127.0.0.1:8080}"
MODELS=("$@")
if [[ ${#MODELS[@]} -eq 0 ]]; then
  MODELS=(gemma3:4b deepseek-r1:1.5b)
fi

pass=0
fail=0
check() {
  local name="$1"
  shift
  if "$@"; then
    echo "PASS  $name"
    pass=$((pass + 1))
  else
    echo "FAIL  $name"
    fail=$((fail + 1))
  fi
}

echo "=== SMOKE ($BASE) ==="
check "GET /" curl -sf -o /dev/null "$BASE/"
check "GET /api/models" curl -sf -o /dev/null "$BASE/api/models"
check "GET /api/models/available" curl -sf -m 60 -o /tmp/gpt-available.json "$BASE/api/models/available"
check "available has categories" python3 - <<'PY'
import json
d=json.load(open("/tmp/gpt-available.json"))
assert "models" in d and "max_param_b" in d
assert all("category" in m for m in d["models"][:5] or [{"category":"x"}])
PY
check "pull rejects missing tag" python3 - <<PY
import json,urllib.request
req=urllib.request.Request(
  "$BASE/api/models/pull",
  data=b'{"name":"llama3.1:4b"}',
  headers={"Content-Type":"application/json"},
  method="POST",
)
with urllib.request.urlopen(req, timeout=30) as r:
  body=r.read().decode()
assert "not found" in body.lower() or "error" in body.lower()
PY

echo
echo "=== BENCHMARK ==="
printf '%-22s %10s %10s %10s %8s\n' MODEL LOAD_S CHAT_S TOK_S DEVICE
for model in "${MODELS[@]}"; do
  enc=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$model")
  curl -sf -X POST "$BASE/api/models/${enc}/stop" >/dev/null 2>&1 || true
  "$ROOT/ollama-isolated.sh" stop "$model" >/dev/null 2>&1 || true
  sleep 0.5

  wall_start=$(date +%s.%N)
  if ! curl -sf -m 600 -o /tmp/gpt-load.json -X POST "$BASE/api/models/${enc}/start"; then
    printf '%-22s %10s %10s %10s %8s\n' "$model" FAIL - - -
    fail=$((fail + 1))
    continue
  fi
  wall_end=$(date +%s.%N)

  load_s=$(python3 - <<'PY'
import json
d=json.load(open("/tmp/gpt-load.json"))
print(f"{(d.get('load_duration') or 0)/1e9:.3f}")
PY
)
  device=$(python3 -c 'import json; print(json.load(open("/tmp/gpt-load.json")).get("device","?"))')
  wall_s=$(python3 -c "print(f'{float('$wall_end')-float('$wall_start'):.3f}')")

  chat_start=$(date +%s.%N)
  curl -sf -m 300 -o /tmp/gpt-chat.ndjson -X POST "$BASE/api/models/${enc}/chat" \
    -H 'Content-Type: application/json' \
    -d '{"message":"Reply with exactly: OK","history":[],"think":false,"images":[]}'
  chat_end=$(date +%s.%N)
  chat_s=$(python3 -c "print(f'{float('$chat_end')-float('$chat_start'):.3f}')")
  tok_s=$(python3 - <<'PY'
import json
tok=None
for line in open("/tmp/gpt-chat.ndjson"):
  line=line.strip()
  if not line: continue
  try: d=json.loads(line)
  except Exception: continue
  if d.get("eval_count") and d.get("eval_duration"):
    tok = d["eval_count"] / (d["eval_duration"] / 1e9)
  if d.get("overhead_breakdown"):
    pass
print(f"{tok:.1f}" if tok else "-")
PY
)
  printf '%-22s %10s %10s %10s %8s  (wall_start=%s)\n' "$model" "$load_s" "$chat_s" "$tok_s" "$device" "$wall_s"
  pass=$((pass + 1))
  curl -sf -X POST "$BASE/api/models/${enc}/stop" >/dev/null 2>&1 || true
done

echo
echo "=== SUMMARY pass=$pass fail=$fail ==="
[[ "$fail" -eq 0 ]]
