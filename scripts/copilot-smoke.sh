#!/usr/bin/env bash
set -euo pipefail

# Copilot CLI smoke test: verifies prompt piping works via the local wrapper.
# Uses a stub copilot binary to avoid network calls.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/ai-autonomous-loop-macos-copilot.sh"

STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

cat >"$STUB_DIR/copilot" <<'EOF'
#!/usr/bin/env bash
echo "MODEL=$COPILOT_MODEL"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) echo "ARG_MODEL=$2"; shift 2 ;;
    -p|--prompt) echo "PROMPT_START"; cat <<<"$2"; echo "PROMPT_END"; shift 2 ;;
    *) shift ;;
  esac
done
EOF
chmod +x "$STUB_DIR/copilot"

export COPILOT_CMD="$STUB_DIR/copilot"
export ALLOW_NO_COPILOT=1
export COPILOT_DEFAULT_MODEL="gpt-4.1"
export COPILOT_FREE_MODEL="gpt-4.1"
export COPILOT_BUILDER_CHAIN="copilot:gpt-4.1"
export COPILOT_REVIEW_CHAIN="copilot:gpt-4.1"
export GIT_AUTO_PUSH_MAIN=0
export GIT_PUSH_ON_FAILURE=0
export TMUX_TIME_LIMIT=1
export COPILOT_TIME_LIMIT=5
export MAX_STAGNANT_ITERS=1
export AI_LOOP_DISABLE_WALLCLOCK_LIMIT=1
export AI_LOOP_KEEP_ARTIFACTS=1
export PREFER_INTERACTIVE_BUILDERS=0

cd "$ROOT"

if ! bash "$SCRIPT" 2>&1 | tee "$STUB_DIR/run.log"; then
  echo "Smoke run failed"
  exit 1
fi

if ! grep -q "PROMPT_START" "$STUB_DIR/run.log"; then
  echo "Smoke validation failed: prompt not piped"
  exit 1
fi

echo "Copilot smoke test passed"
