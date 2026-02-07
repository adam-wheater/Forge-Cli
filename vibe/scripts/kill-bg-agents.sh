#!/usr/bin/env bash
set -uo pipefail
# Kill background AI agents, copilot processes, and orphaned build processes
# Preserves the current interactive Claude session (pts terminal sessions)

echo "Killing background Claude agents..."

# Kill Claude subagents (stream-json processes spawned by Task tool)
pkill -f "claude.*--output-format stream-json" 2>/dev/null && echo "  Killed Claude subagents" || echo "  No Claude subagents found"

# Kill Claude processes with --resume flag (orphaned subagents)
pkill -f "claude.*--resume" 2>/dev/null && echo "  Killed resumed Claude sessions" || echo "  No resumed sessions found"

# Give processes time to terminate gracefully
sleep 1

# Force kill any remaining Claude background processes (not in terminals)
for pid in $(pgrep -f "/root/.local/bin/claude" 2>/dev/null || true); do
  # Check if process is running in a terminal (interactive) - preserve those
  if ! ps -p "$pid" -o tty= 2>/dev/null | grep -q "pts"; then
    kill -9 "$pid" 2>/dev/null && echo "  Force killed background Claude PID $pid"
  fi
done

echo "Killing GitHub Copilot processes..."
pkill -f "/usr/local/bin/copilot" 2>/dev/null && echo "  Killed Copilot processes" || echo "  No Copilot processes found"

echo "Killing timeout wrappers..."
pkill -f "timeout.*copilot" 2>/dev/null && echo "  Killed timeout wrappers" || echo "  No timeout wrappers found"

echo "Killing ai-autonomous-loop script..."
pkill -f "ai-autonomous-loop" 2>/dev/null && echo "  Killed AI loop script" || echo "  No AI loop script found"

echo "Killing orphaned MSBuild processes..."
pkill -f "MSBuild.dll.*nodemode" 2>/dev/null && echo "  Killed MSBuild processes" || echo "  No MSBuild processes found"

# Count zombies (can't be killed, just report)
zombie_count=$(ps aux 2>/dev/null | grep '\[claude\].*<defunct>' | wc -l)
if [ "${zombie_count:-0}" -gt 0 ]; then
  echo ""
  echo "Note: $zombie_count zombie processes exist (will be reaped automatically)"
fi

echo ""
echo "Done. Remaining agent processes:"
ps aux | grep -E "(claude|copilot|MSBuild|ai-autonomous)" | grep -v grep | grep -v "kill-bg-agents" || echo "  None"
