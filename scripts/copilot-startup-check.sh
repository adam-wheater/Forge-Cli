#!/usr/bin/env bash
set -euo pipefail

# Quick Copilot CLI startup sanity check.
# Usage: COPILOT_MODEL=gpt-4.1 ./scripts/copilot-startup-check.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

COPILOT_CMD="${COPILOT_CMD:-$(command -v copilot || true)}"
MODEL="${COPILOT_MODEL:-gpt-4.1}"
PROMPT="${COPILOT_PROMPT:-Say hello from Copilot startup check.}"
TIMEOUT_SECONDS="${COPILOT_CHECK_TIMEOUT:-30}"

if [ -z "$COPILOT_CMD" ]; then
  echo "ERROR: copilot CLI not found on PATH." >&2
  exit 1
fi

if [ -n "${DEBUG:-}" ]; then
  set -x
fi

run_with_timeout() {
  local seconds="$1"
  shift
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$seconds" "$@"
    return $?
  fi
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
    return $?
  fi
  python3 - "$seconds" "$@" <<'PY'
import os, signal, subprocess, sys
seconds = int(sys.argv[1]); cmd = sys.argv[2:]
try:
  proc = subprocess.Popen(cmd, preexec_fn=os.setsid)
  proc.wait(timeout=seconds)
  raise SystemExit(proc.returncode)
except subprocess.TimeoutExpired:
  try: os.killpg(proc.pid, signal.SIGTERM)
  except Exception: pass
  try: proc.wait(timeout=5)
  except Exception:
    try: os.killpg(proc.pid, signal.SIGKILL)
    except Exception: pass
  raise SystemExit(124)
PY
}

echo "Running Copilot CLI sanity check..."
echo "  Copilot: $COPILOT_CMD"
echo "  Model:   $MODEL"
echo "  Prompt:  $PROMPT"

LOG_FILE="$(mktemp)"
trap 'rm -f "$LOG_FILE"' EXIT

if run_with_timeout "$TIMEOUT_SECONDS" "$COPILOT_CMD" --model "$MODEL" --yolo --prompt "$PROMPT" >"$LOG_FILE" 2>&1; then
  echo "✅ Copilot CLI responded:"
  cat "$LOG_FILE"
  exit 0
fi

STATUS=$?
echo "❌ Copilot CLI failed (exit $STATUS). Output:"
cat "$LOG_FILE"
exit "$STATUS"
