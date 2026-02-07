#!/usr/bin/env bash
# Note: set -e removed intentionally - errors are caught and auto-resolved
set -uo pipefail

# ============================================================
# ⚠️  THIS IS NOT PART OF THE FORGE CLI TOOL.
# This is the development-time AI loop script used to build
# and iterate on the Forge CLI with Claude/Copilot agents.
# Do NOT modify this file when working on Forge CLI features.
# The Forge CLI lives in: lib/, agents/, run.ps1, memory/
# ============================================================
#
# AUTONOMOUS SOFTWARE FACTORY — LINUX (CLAUDE-FIRST WITH COPILOT FALLBACK)
# CLAUDE CLI OR COPILOT CLI AUTOMATES BUILDERS & REVIEWERS
#
# Run every builder and reviewer pass through Claude Code by default, falling
# back to Copilot premium models, then Copilot free if credits are exhausted.
# Configure the pipelines via the environment.
# ============================================================

# Path helpers
prepend_to_path() {
  local dir="$1"
  if [ -n "$dir" ] && [ -d "$dir" ] && [[ ":$PATH:" != *":$dir:"* ]]; then
    PATH="$dir:$PATH"
  fi
}

append_to_path() {
  local dir="$1"
  if [ -n "$dir" ] && [ -d "$dir" ] && [[ ":$PATH:" != *":$dir:"* ]]; then
    PATH="$PATH:$dir"
  fi
}

refresh_command_cache() {
  hash -r 2>/dev/null || true
}

# Allow user-level .NET installs to surface automatically.
export DOTNET_ROOT="${DOTNET_ROOT:-$HOME/.dotnet}"
prepend_to_path "$DOTNET_ROOT"
prepend_to_path "$DOTNET_ROOT/tools"
export PATH
refresh_command_cache

# ----------------------------
# OS-aware defaults and dependency bootstrap
# ----------------------------
OS_NAME="$(uname -s 2>/dev/null || echo Unknown)"
IS_LINUX=0
IS_MAC=0
LINUX_PKG_MANAGER=""
LINUX_APT_UPDATED=0

if [ "$OS_NAME" = "Linux" ]; then
  IS_LINUX=1
elif [ "$OS_NAME" = "Darwin" ]; then
  IS_MAC=1
else
  echo "ERROR: Unsupported host OS (detected: $OS_NAME). Supported: Linux, macOS (Darwin)." >&2
  exit 1
fi

if [ "$IS_MAC" -eq 1 ]; then
  prepend_to_path "/opt/homebrew/bin"
  prepend_to_path "/opt/homebrew/sbin"
  prepend_to_path "/usr/local/bin"
  prepend_to_path "/usr/local/sbin"
  export PATH
  refresh_command_cache
fi

run_priv() {
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    "$@"
  fi
}

linux_detect_package_manager() {
  if [ "$IS_LINUX" -ne 1 ]; then
    return 1
  fi
  if [ -n "$LINUX_PKG_MANAGER" ]; then
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    LINUX_PKG_MANAGER="apt"
  elif command -v dnf >/dev/null 2>&1; then
    LINUX_PKG_MANAGER="dnf"
  elif command -v pacman >/dev/null 2>&1; then
    LINUX_PKG_MANAGER="pacman"
  elif command -v zypper >/dev/null 2>&1; then
    LINUX_PKG_MANAGER="zypper"
  else
    return 1
  fi
}

linux_install_packages() {
  if [ "$IS_LINUX" -ne 1 ]; then
    return 0
  fi
  linux_detect_package_manager || return 1
  if [ $# -eq 0 ]; then
    return 0
  fi

  local packages=("$@")

  case "$LINUX_PKG_MANAGER" in
    apt)
      if [ $LINUX_APT_UPDATED -eq 0 ]; then
        run_priv apt-get update
        LINUX_APT_UPDATED=1
      fi
      run_priv env DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
      ;;
    dnf)
      run_priv dnf install -y "${packages[@]}"
      ;;
    pacman)
      run_priv pacman -Sy --needed --noconfirm "${packages[@]}"
      ;;
    zypper)
      run_priv zypper --non-interactive install "${packages[@]}"
      ;;
    *)
      return 1
      ;;
  esac
}

ensure_linux_command() {
  if [ "$IS_LINUX" -ne 1 ]; then
    return 0
  fi
  local cmd="$1"
  shift
  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi
  linux_install_packages "$@" || return 1
  refresh_command_cache
  command -v "$cmd" >/dev/null 2>&1
}

ensure_node_tooling() {
  if command -v npm >/dev/null 2>&1; then
    local npm_bin
    npm_bin="$(npm bin -g 2>/dev/null || true)"
    append_to_path "$npm_bin"
    export PATH
    refresh_command_cache
    return 0
  fi

  if [ "$IS_LINUX" -eq 1 ]; then
    if ! linux_install_packages nodejs npm; then
      return 1
    fi
  elif [ "$IS_MAC" -eq 1 ]; then
    if command -v brew >/dev/null 2>&1; then
      if ! brew install node; then
        return 1
      fi
    else
      echo "ERROR: npm not found and Homebrew unavailable on macOS." >&2
      return 1
    fi
  fi

  local npm_bin
  npm_bin="$(npm bin -g 2>/dev/null || true)"
  append_to_path "$npm_bin"
  export PATH
  refresh_command_cache

  command -v npm >/dev/null 2>&1
}

install_dotnet_cli() {
  if command -v dotnet >/dev/null 2>&1; then
    return 0
  fi

  if [ "$IS_LINUX" -eq 1 ]; then
    ensure_linux_command curl curl || return 1
  elif [ "$IS_MAC" -eq 1 ] && command -v brew >/dev/null 2>&1; then
    if run_priv brew install dotnet-sdk; then
      export DOTNET_ROOT="${DOTNET_ROOT:-/usr/local/share/dotnet}"
      prepend_to_path "$DOTNET_ROOT"
      prepend_to_path "$DOTNET_ROOT/tools"
      export PATH
      refresh_command_cache
      return 0
    fi
  fi

  local install_script
  install_script="$(mktemp -t dotnet-install.XXXXXX)"

  if ! curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$install_script"; then
    rm -f "$install_script"
    return 1
  fi

  if ! bash "$install_script" --channel STS; then
    if ! bash "$install_script" --version 10.0.101; then
      rm -f "$install_script"
      return 1
    fi
  fi

  rm -f "$install_script"

  export DOTNET_ROOT="${DOTNET_ROOT:-$HOME/.dotnet}"
  prepend_to_path "$DOTNET_ROOT"
  prepend_to_path "$DOTNET_ROOT/tools"
  export PATH
  refresh_command_cache

  command -v dotnet >/dev/null 2>&1
}

install_copilot_cli() {
  if command -v copilot >/dev/null 2>&1; then
    return 0
  fi

  if ! ensure_node_tooling; then
    return 1
  fi

  local npm_cmd=(npm install -g @githubnext/github-copilot-cli)
  if command -v sudo >/dev/null 2>&1; then
    npm_cmd=(sudo "${npm_cmd[@]}")
  fi

  if ! "${npm_cmd[@]}"; then
    return 1
  fi

  local npm_bin
  npm_bin="$(npm bin -g 2>/dev/null || true)"
  append_to_path "$npm_bin"
  export PATH
  refresh_command_cache

  command -v copilot >/dev/null 2>&1
}

bootstrap_dependencies() {
  if [ "$IS_LINUX" -eq 1 ]; then
    if ! linux_detect_package_manager; then
      echo "WARNING: No supported package manager found; automatic dependency installation skipped." >&2
    else
      ensure_linux_command git git || {
        echo "ERROR: Unable to install git." >&2
        exit 1
      }

      ensure_linux_command tmux tmux || {
        echo "ERROR: Unable to install tmux." >&2
        exit 1
      }

      ensure_linux_command timeout coreutils || {
        echo "ERROR: Unable to install coreutils (timeout)." >&2
        exit 1
      }

      ensure_linux_command python3 python3 || {
        echo "ERROR: Unable to install python3." >&2
        exit 1
      }
    fi
  fi

  # dotnet is optional for PowerShell projects
  install_dotnet_cli || {
    echo "INFO: .NET SDK not available (optional for PowerShell projects)." >&2
  }

  if [ "${ALLOW_NO_COPILOT:-0}" -ne 1 ]; then
    install_copilot_cli || {
      echo "ERROR: Unable to install the GitHub Copilot CLI. Set ALLOW_NO_COPILOT=1 to bypass." >&2
      exit 1
    }
  else
    install_copilot_cli || true
  fi
}

DEFAULT_DOTNET_TFM="net10.0"
bootstrap_dependencies

# ----------------------------
# Resolve project directory
# ----------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel 2>/dev/null || echo "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

STATE_DIR="${STATE_DIR:-$SCRIPT_DIR/.ai-metrics}"

# Ensure script stays executable (editors/tools may strip the bit)
chmod +x "$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")" 2>/dev/null

find_first_match() {
  local pattern="$1"
  find "$PROJECT_DIR" \
    \( -path "$PROJECT_DIR/.git" -o -path "$PROJECT_DIR/.git/*" \
       -o -path "$STATE_DIR" -o -path "$STATE_DIR/*" \
       -o -path "$PROJECT_DIR/bin" -o -path "$PROJECT_DIR/bin/*" \
       -o -path "$PROJECT_DIR/obj" -o -path "$PROJECT_DIR/obj/*" \
       -o -path "$PROJECT_DIR/node_modules" -o -path "$PROJECT_DIR/node_modules/*" \
    \) -prune -o -type f -name "$pattern" -print -quit
}

DEFAULT_SOLUTION_PATH="$(find_first_match '*.sln')"
DEFAULT_PROJECT_PATH="$(find_first_match '*.csproj')"
# PowerShell project detection
DEFAULT_PS1_ENTRY="$(find_first_match 'run.ps1')"
if [ -z "$DEFAULT_PS1_ENTRY" ]; then
  DEFAULT_PS1_ENTRY="$(find_first_match '*.ps1')"
fi
IS_POWERSHELL_PROJECT=0
if [ -n "$DEFAULT_PS1_ENTRY" ] && [ -z "$DEFAULT_PROJECT_PATH" ]; then
  IS_POWERSHELL_PROJECT=1
fi

detect_default_tfm() {
  local csproj="$1"
  if [ -z "$csproj" ] || [ ! -f "$csproj" ]; then
    echo ""
    return 0
  fi

  python3 - "$csproj" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="ignore")

def first_match(pattern):
    m = re.search(pattern, text, re.IGNORECASE)
    return m.group(1).strip() if m else None

def emit_first_concrete(values):
    for raw in values:
        candidate = raw.strip()
        if not candidate or "$(" in candidate:
            continue
        lowered = candidate.lower()
        if "tizen" in lowered:
            continue
        print(candidate)
        raise SystemExit

tfm = first_match(r"<TargetFramework>\s*([^<\s]+)\s*</TargetFramework>")
if tfm:
    emit_first_concrete([tfm])

tfms = first_match(r"<TargetFrameworks>\s*([^<]+)\s*</TargetFrameworks>")
if tfms:
    emit_first_concrete(tfms.split(";"))

base_tfm = first_match(r"<BaseTargetFrameworks>\s*([^<\s]+)\s*</BaseTargetFrameworks>")
if base_tfm:
    emit_first_concrete([base_tfm])

print("")
PY
}

# ----------------------------
# Trust workspace directory
# ----------------------------
if command -v git >/dev/null 2>&1; then
  git config --global --add safe.directory "$PROJECT_DIR" || true
fi

# ----------------------------
# Locate tools
# ----------------------------
: "${ALLOW_NO_COPILOT:=1}"

COPILOT_CMD="${COPILOT_CMD:-$(command -v copilot || true)}"
TMUX_CMD="${TMUX_CMD:-$(command -v tmux || true)}"
DOTNET_CMD="${DOTNET_CMD:-$(command -v dotnet || true)}"

if [ -z "$COPILOT_CMD" ] && [ "$ALLOW_NO_COPILOT" -ne 1 ]; then
  echo "ERROR: copilot CLI not found" >&2
  exit 1
fi
if [ -z "$TMUX_CMD" ]; then
  echo "ERROR: tmux not found" >&2
  exit 1
fi
# dotnet is optional for PowerShell projects
if [ -z "$DOTNET_CMD" ]; then
  echo "INFO: dotnet not found (optional for PowerShell projects)" >&2
fi

# ----------------------------
# Basic config
# ----------------------------
MAIN_BRANCH="${MAIN_BRANCH:-main}"
WORK_BRANCH="${WORK_BRANCH:-ai-work}"
TMUX_SESSION="${TMUX_SESSION:-ai-loop}"
SOLUTION_PATH="${SOLUTION_PATH:-$DEFAULT_SOLUTION_PATH}"
PROJECT_PATH="${PROJECT_PATH:-$DEFAULT_PROJECT_PATH}"
DOTNET_CONFIGURATION="${DOTNET_CONFIGURATION:-Debug}"
auto_tfm="$(detect_default_tfm "$DEFAULT_PROJECT_PATH")"
if [ -n "$auto_tfm" ]; then
  DEFAULT_DOTNET_TFM="$auto_tfm"
fi
# Leave DOTNET_TARGET_FRAMEWORK empty to allow per-platform restore to choose supported TFM.
DOTNET_TARGET_FRAMEWORK="${DOTNET_TARGET_FRAMEWORK:-}"

BUG_HUNT_EVERY="${BUG_HUNT_EVERY:-5}"
# Stability mode disabled - errors are auto-resolved via Claude
STABILITY_EVERY="${STABILITY_EVERY:-999999}"

TMUX_TIME_LIMIT="${TMUX_TIME_LIMIT:-1800}"
COPILOT_TIME_LIMIT="${COPILOT_TIME_LIMIT:-900}"

# Pipelines are comma-separated lists of CLI specifications in the
# form "copilot:gpt-5.2". Each specification is executed sequentially
# for every prompt during that phase.
: "${COPILOT_BUILDER_CHAIN:=copilot:gpt-5.2,copilot:gpt-4.1}"
: "${COPILOT_REVIEW_CHAIN:=copilot:gpt-4.1}"
: "${CLAUDE_BUILDER_CHAIN:=claude:${CLAUDE_MODEL:-claude-sonnet-4-20250514},copilot:gpt-5.2,copilot:gpt-4.1}"
: "${CLAUDE_REVIEW_CHAIN:=claude:${CLAUDE_MODEL:-claude-sonnet-4-20250514},copilot:gpt-4.1}"

COPILOT_DEFAULT_MODEL="${COPILOT_DEFAULT_MODEL:-gpt-5.2}"
: "${COPILOT_FREE_MODEL:=gpt-4.1}"
: "${CLAUDE_CMD:=$(command -v claude || true)}"
: "${CLAUDE_MODEL:=claude-sonnet-4-20250514}"
# Permission bypass: use --permission-mode for root (bypassPermissions is rejected),
# --dangerously-skip-permissions otherwise
if [ "$(id -u)" -eq 0 ]; then
  : "${CLAUDE_ARGS:=--permission-mode acceptEdits}"
else
  : "${CLAUDE_ARGS:=--dangerously-skip-permissions}"
fi
: "${COPILOT_PREMIUM_MODEL_PATTERN:=gpt-5\.2}"
# More specific regex to avoid false positives from discussion of credits/limits in code/text
: "${COPILOT_CREDIT_ERROR_REGEX:=HTTP.*402|status.*402|error.*402|no quota|you have no quota|quota exceeded|out of credits|credits exhausted|usage limit exceeded|rate limit exceeded|billing error|payment required|requires copilot pro|not included in your plan|increase your limit|features/copilot/plans|upgrade.*plan}"
# Treat plan/entitlement failures (premium not permitted) as enablement failures so we immediately drop to free.
: "${COPILOT_MODEL_ENABLE_ERROR_REGEX:=enable this model|interactive mode to enable this model|not enabled for your account|model not enabled|not available for your account|not available on your plan|not permitted on your plan}"
COPILOT_PREMIUM_AVAILABLE=1
: "${COPILOT_FORCE_FREE_ONLY:=0}"
if [ "$COPILOT_FORCE_FREE_ONLY" -eq 1 ]; then
  COPILOT_PREMIUM_AVAILABLE=0
fi
COPILOT_PREMIUM_BLACKLIST=()
COPILOT_LAST_LOG=""
COPILOT_PREMIUM_NOTICE_SHOWN=0

PREFER_INTERACTIVE_BUILDERS="${PREFER_INTERACTIVE_BUILDERS:-1}"

: "${GIT_AUTO_PUSH_MAIN:=1}"
: "${GIT_PUSH_REMOTE:=origin}"
: "${GIT_PUSH_ON_FAILURE:=0}"

MAX_STAGNANT_ITERS="${MAX_STAGNANT_ITERS:-5}"
: "${MAX_WALL_HOURS:=48}"

DEFAULT_REPO_URL="$(git config --get remote.origin.url 2>/dev/null || true)"
REPO_URL="${REPO_URL:-$DEFAULT_REPO_URL}"

# ----------------------------
# State
# ----------------------------
mkdir -p "$STATE_DIR"

LAST_HASH_FILE="$STATE_DIR/last_hash.txt"
STAGNANT_COUNT_FILE="$STATE_DIR/stagnant_count.txt"
START_TIME_FILE="$STATE_DIR/start_time.txt"
FORCED_MODE_FILE="$STATE_DIR/forced_mode.txt"
LOG_FILE="$STATE_DIR/ai-loop.log"
STATUS_FILE="$STATE_DIR/status.txt"

# Logging functions
log() {
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$timestamp] $*" | tee -a "$LOG_FILE"
}

log_status() {
  local status="$1"
  echo "$status" > "$STATUS_FILE"
  log "STATUS: $status"
}

log_progress() {
  local phase="$1"
  local detail="$2"
  local icon=""
  case "$phase" in
    ITER*) icon="🔄" ;;
    BUILD*) icon="🔨" ;;
    TEST*) icon="🧪" ;;
    REVIEW*) icon="👀" ;;
    MERGE*) icon="🔀" ;;
    PUSH*) icon="📤" ;;
    DONE*) icon="✅" ;;
    ERROR*) icon="❌" ;;
    MEMORY*) icon="🧠" ;;
    CLEANUP*) icon="🧹" ;;
    *) icon="▶️" ;;
  esac
  log "$icon $phase: $detail"
}

# ----------------------------
# Memory management functions
# ----------------------------
: "${MIN_MEMORY_MB:=1024}"           # Minimum 1GB free for full agents
: "${LOW_MEMORY_MB:=2048}"           # Below 2GB, reduce agent count
: "${MEMORY_AGENT_FULL:=5}"          # Full agent count when memory sufficient
: "${MEMORY_AGENT_REDUCED:=2}"       # Reduced agent count when memory constrained

get_available_memory_mb() {
  # Returns available memory in MB (works on Linux and macOS)
  local mem_mb=0
  if [ "$IS_LINUX" -eq 1 ]; then
    # On Linux, use /proc/meminfo for available memory
    mem_mb=$(awk '/MemAvailable/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo "0")
    if [ "$mem_mb" -eq 0 ]; then
      # Fallback: free memory + buffers/cache
      mem_mb=$(free -m 2>/dev/null | awk '/^Mem:/ {print $7}' || echo "0")
    fi
  elif [ "$IS_MAC" -eq 1 ]; then
    # On macOS, use vm_stat
    local pages_free pages_inactive page_size
    page_size=$(pagesize 2>/dev/null || echo "4096")
    pages_free=$(vm_stat 2>/dev/null | awk '/Pages free/ {gsub(/\./,""); print $3}' || echo "0")
    pages_inactive=$(vm_stat 2>/dev/null | awk '/Pages inactive/ {gsub(/\./,""); print $3}' || echo "0")
    mem_mb=$(( (pages_free + pages_inactive) * page_size / 1024 / 1024 ))
  fi
  echo "$mem_mb"
}

get_total_memory_mb() {
  local mem_mb=0
  if [ "$IS_LINUX" -eq 1 ]; then
    mem_mb=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo "0")
  elif [ "$IS_MAC" -eq 1 ]; then
    mem_mb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo "0") / 1024 / 1024 ))
  fi
  echo "$mem_mb"
}

check_memory_available() {
  local min_required="${1:-$MIN_MEMORY_MB}"
  local available
  available=$(get_available_memory_mb)
  if [ "$available" -lt "$min_required" ]; then
    return 1
  fi
  return 0
}

get_recommended_agent_count() {
  local available
  available=$(get_available_memory_mb)
  if [ "$available" -ge "$LOW_MEMORY_MB" ]; then
    echo "$MEMORY_AGENT_FULL"
  elif [ "$available" -ge "$MIN_MEMORY_MB" ]; then
    echo "$MEMORY_AGENT_REDUCED"
  else
    # Even with very low memory, run at least 1 agent
    echo "1"
  fi
}

cleanup_zombie_processes() {
  log_progress "CLEANUP" "Cleaning up Claude processes and zombies"

  # Kill orphaned Claude subagent processes (background stream-json processes)
  local subagent_pids
  subagent_pids=$(pgrep -f "claude.*--output-format stream-json" 2>/dev/null || true)
  if [ -n "$subagent_pids" ]; then
    for pid in $subagent_pids; do
      # Only kill if not our parent process
      if [ "$pid" != "$$" ] && [ "$pid" != "$PPID" ]; then
        kill -15 "$pid" 2>/dev/null || true
      fi
    done
    log "  Sent SIGTERM to Claude subagents: $subagent_pids"
    sleep 1
    # Force kill any that didn't terminate
    for pid in $subagent_pids; do
      if [ "$pid" != "$$" ] && [ "$pid" != "$PPID" ] && kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
      fi
    done
  fi

  # Kill any orphaned Claude processes from previous runs (--print pattern)
  local orphan_pids
  orphan_pids=$(pgrep -f "claude.*--print" 2>/dev/null || true)
  if [ -n "$orphan_pids" ]; then
    for pid in $orphan_pids; do
      if [ "$pid" != "$$" ] && [ "$pid" != "$PPID" ]; then
        kill -15 "$pid" 2>/dev/null || true
      fi
    done
    log "  Sent SIGTERM to orphaned Claude processes"
  fi

  # Note: Zombie processes (defunct) cannot be killed directly - they are already dead.
  # They are removed when their parent calls wait() or when the parent dies.
  # Count them for logging purposes only.
  local zombie_count
  zombie_count=$(ps aux 2>/dev/null | grep -c '\[claude\].*<defunct>' || true)
  zombie_count="${zombie_count:-0}"
  if [ "$zombie_count" -gt 0 ] 2>/dev/null; then
    log "  Note: $zombie_count zombie processes exist (will be reaped when parent exits)"
  fi

  # Clean up any stale tmux sessions from previous runs
  tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
}

cleanup_memory_caches() {
  log_progress "CLEANUP" "Clearing memory caches"

  if [ "$IS_LINUX" -eq 1 ]; then
    # Drop caches (requires root or appropriate permissions)
    if [ "$(id -u)" -eq 0 ]; then
      sync
      echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
      log "  Dropped kernel caches"
    else
      # Non-root: just sync and hope for the best
      sync 2>/dev/null || true
    fi
  fi

  # Clear npm cache if it exists and is large
  if command -v npm >/dev/null 2>&1; then
    npm cache clean --force 2>/dev/null || true
  fi

  # Clear NuGet cache if very large (>500MB)
  local nuget_cache="${HOME}/.nuget/packages"
  if [ -d "$nuget_cache" ]; then
    local cache_size_mb
    cache_size_mb=$(du -sm "$nuget_cache" 2>/dev/null | awk '{print $1}' || echo "0")
    if [ "$cache_size_mb" -gt 500 ]; then
      log "  NuGet cache is ${cache_size_mb}MB - consider manual cleanup"
    fi
  fi
}

run_full_cleanup() {
  log_progress "CLEANUP" "Running full memory cleanup"
  cleanup_zombie_processes
  cleanup_memory_caches

  # Wait for memory to settle
  sleep 5

  local before_mem after_mem
  before_mem=$(get_available_memory_mb)

  # Force garbage collection hint
  sync 2>/dev/null || true
  sleep 2

  after_mem=$(get_available_memory_mb)
  log "  Memory before: ${before_mem}MB, after: ${after_mem}MB (freed: $((after_mem - before_mem))MB)"
}

setup_swap_if_needed() {
  # Only on Linux, and only if no swap exists
  if [ "$IS_LINUX" -ne 1 ]; then
    return 0
  fi

  local swap_total
  swap_total=$(free -m 2>/dev/null | awk '/^Swap:/ {print $2}' || echo "0")

  if [ "$swap_total" -gt 0 ]; then
    log "Swap already configured: ${swap_total}MB"
    return 0
  fi

  # Need root to create swap
  if [ "$(id -u)" -ne 0 ]; then
    log "WARNING: No swap configured and not running as root. Consider adding swap manually."
    return 0
  fi

  log_progress "MEMORY" "No swap detected - creating 2GB swapfile as safety buffer"

  local swapfile="/swapfile"
  if [ -f "$swapfile" ]; then
    log "  Swapfile already exists, enabling..."
  else
    # Create 2GB swapfile
    dd if=/dev/zero of="$swapfile" bs=1M count=2048 status=progress 2>/dev/null || {
      log "  WARNING: Failed to create swapfile"
      return 1
    }
    chmod 600 "$swapfile"
    mkswap "$swapfile" >/dev/null 2>&1 || {
      log "  WARNING: Failed to format swapfile"
      rm -f "$swapfile"
      return 1
    }
  fi

  swapon "$swapfile" 2>/dev/null || {
    log "  WARNING: Failed to enable swapfile"
    return 1
  }

  log "  Swap enabled: 2048MB"
  return 0
}

declare -a DETECTED_LANGUAGES=()
declare -A CONTEXT_RESOURCE_REGISTRY=()
declare -a CONTEXT_RESOURCE_QUEUE=()
SKILL_CONTEXT_BLOCK=""
CURRENT_CONTEXT_SIGNATURE=""

ensure_state_dir() {
  mkdir -p "$STATE_DIR"
  [ -f "$START_TIME_FILE" ] || date +%s > "$START_TIME_FILE"
  [ -f "$STAGNANT_COUNT_FILE" ] || echo 0 > "$STAGNANT_COUNT_FILE"
}

# ============================================================
# TODO COMPLETION CHECK
# Detect when all tasks are done to switch to idle mode
# ============================================================

todo_all_complete() {
  # Check if TODO.md exists and all task items are marked complete
  local todo_file="TODO.md"
  if [ ! -f "$todo_file" ]; then
    return 1  # No TODO file, not complete
  fi

  # Count incomplete items (lines with "- [ ]")
  local incomplete
  incomplete=$(grep -cE '^[[:space:]]*- \[ \]' "$todo_file" 2>/dev/null) || incomplete=0

  # Count complete items (lines with "- [x]" case-insensitive)
  local complete
  complete=$(grep -ciE '^[[:space:]]*- \[x\]' "$todo_file" 2>/dev/null) || complete=0

  # All complete if no incomplete items and at least one complete item
  [ "$incomplete" -eq 0 ] && [ "$complete" -gt 0 ]
}

# ============================================================
# QUOTA/EXHAUSTION MANAGEMENT
# Reset daily, track across iterations within a day
# ============================================================

CLAUDE_EXHAUSTED_FILE="$STATE_DIR/claude_exhausted.flag"
COPILOT_PREMIUM_EXHAUSTED_FILE="$STATE_DIR/copilot_premium_exhausted.flag"
COPILOT_FREE_EXHAUSTED_FILE="$STATE_DIR/copilot_free_exhausted.flag"
COPILOT_FREE_EXHAUSTED_TIME_FILE="$STATE_DIR/copilot_free_exhausted_time.txt"
QUOTA_DAY_FILE="$STATE_DIR/quota_day.txt"
# More specific regex to avoid false positives from Claude's own output text
# Only match actual API error messages, not general discussion about quotas/limits
: "${CLAUDE_QUOTA_REGEX:=Error:.*quota|Error:.*rate.?limit|Error:.*usage.?limit|Error:.*limit.?reached|Error:.*payment.?required|Error:.*402|Error:.*429|API.?error.*quota|API.?error.*limit|exceeded your.*quota|reached your.*limit|out of.*credits|billing.?error|HTTPError.*402|HTTPError.*429}"
: "${COPILOT_FREE_WAIT_MINUTES:=60}"
CURRENT_AGENT="claude"

reset_daily_quota_flags() {
  local today
  today="$(date -u +%F)"
  local current
  current="$(cat "$QUOTA_DAY_FILE" 2>/dev/null || echo "")"
  if [ "$current" != "$today" ]; then
    echo "New day detected ($today). Resetting quota flags." >&2
    rm -f "$CLAUDE_EXHAUSTED_FILE" "$COPILOT_PREMIUM_EXHAUSTED_FILE" "$COPILOT_FREE_EXHAUSTED_FILE" "$COPILOT_FREE_EXHAUSTED_TIME_FILE"
    echo "$today" > "$QUOTA_DAY_FILE"
    CURRENT_AGENT="claude"
  fi
}

mark_claude_exhausted() {
  touch "$CLAUDE_EXHAUSTED_FILE"
  echo "NOTICE: Claude Code daily tokens exhausted. Switching to Copilot premium." >&2
  CURRENT_AGENT="copilot-premium"
}

mark_copilot_premium_exhausted() {
  touch "$COPILOT_PREMIUM_EXHAUSTED_FILE"
  echo "NOTICE: Copilot premium credits exhausted. Switching to Copilot free model." >&2
  CURRENT_AGENT="copilot-free"
  COPILOT_PREMIUM_AVAILABLE=0
}

mark_copilot_free_exhausted() {
  touch "$COPILOT_FREE_EXHAUSTED_FILE"
  date +%s > "$COPILOT_FREE_EXHAUSTED_TIME_FILE"
  echo "NOTICE: Copilot free tier quota exhausted. Waiting ${COPILOT_FREE_WAIT_MINUTES} minutes for reset." >&2
  CURRENT_AGENT="none"
}

copilot_free_available() {
  if [ ! -f "$COPILOT_FREE_EXHAUSTED_FILE" ]; then
    return 0
  fi

  # Check if enough time has passed since exhaustion
  if [ -f "$COPILOT_FREE_EXHAUSTED_TIME_FILE" ]; then
    local exhausted_time now_time elapsed_mins
    exhausted_time="$(cat "$COPILOT_FREE_EXHAUSTED_TIME_FILE" 2>/dev/null || echo "0")"
    now_time="$(date +%s)"
    elapsed_mins=$(( (now_time - exhausted_time) / 60 ))

    if [ "$elapsed_mins" -ge "$COPILOT_FREE_WAIT_MINUTES" ]; then
      echo "NOTICE: Copilot free tier cooldown complete ($elapsed_mins mins elapsed). Re-enabling." >&2
      rm -f "$COPILOT_FREE_EXHAUSTED_FILE" "$COPILOT_FREE_EXHAUSTED_TIME_FILE"
      return 0
    fi

    local remaining_mins=$((COPILOT_FREE_WAIT_MINUTES - elapsed_mins))
    echo "Copilot free tier waiting for quota reset: ${remaining_mins} minutes remaining." >&2
  fi

  return 1
}

claude_available_today() {
  [ -n "$CLAUDE_CMD" ] && [ ! -f "$CLAUDE_EXHAUSTED_FILE" ]
}

copilot_premium_available_today() {
  [ ! -f "$COPILOT_PREMIUM_EXHAUSTED_FILE" ] && [ "$COPILOT_PREMIUM_AVAILABLE" -eq 1 ]
}

get_current_agent() {
  if claude_available_today; then
    echo "claude"
  elif copilot_premium_available_today; then
    echo "copilot-premium"
  elif copilot_free_available; then
    echo "copilot-free"
  else
    echo "none"
  fi
}

log_agent_status() {
  local agent
  agent="$(get_current_agent)"
  local claude_status="available"
  local copilot_premium_status="available"
  local copilot_free_status="available"

  [ -f "$CLAUDE_EXHAUSTED_FILE" ] && claude_status="exhausted"
  [ -z "$CLAUDE_CMD" ] && claude_status="not installed"
  [ -f "$COPILOT_PREMIUM_EXHAUSTED_FILE" ] && copilot_premium_status="exhausted"
  [ "$COPILOT_PREMIUM_AVAILABLE" -eq 0 ] && copilot_premium_status="unavailable"
  [ -f "$COPILOT_FREE_EXHAUSTED_FILE" ] && copilot_free_status="quota exhausted (waiting)"

  echo "Agent Status: Claude=$claude_status, Copilot Premium=$copilot_premium_status, Copilot Free=$copilot_free_status" >&2
  echo "Current Active Agent: $agent" >&2
}

claude_log_indicates_quota_exhaustion() {
  local log_text="$1"
  if [ -z "$log_text" ]; then
    return 1
  fi
  if [ -z "$CLAUDE_QUOTA_REGEX" ]; then
    return 1
  fi
  echo "$log_text" | grep -Eiq -- "$CLAUDE_QUOTA_REGEX"
}

ensure_git_identity() {
  if ! command -v git >/dev/null 2>&1; then
    return 0
  fi

  local name email
  name="$(git config --global user.name 2>/dev/null || true)"
  email="$(git config --global user.email 2>/dev/null || true)"

  if [ -n "$name" ] && [ -n "$email" ]; then
    return 0
  fi

  if [ ! -t 0 ]; then
    echo "ERROR: git user.name/user.email not configured and no TTY available to prompt." >&2
    echo "Run: git config --global user.name 'Your Name' && git config --global user.email 'you@example.com'" >&2
    exit 1
  fi

  if [ -z "$name" ]; then
    read -rp "Enter git user.name: " name
    if [ -n "$name" ]; then
      git config --global user.name "$name"
    fi
  fi

  if [ -z "$email" ]; then
    read -rp "Enter git user.email: " email
    if [ -n "$email" ]; then
      git config --global user.email "$email"
    fi
  fi
}

trim() {
  local input="$1"
  # shellcheck disable=SC2001
  echo "$input" | sed -E 's/^\s+//; s/\s+$//'
}

mktemp_file() {
  mktemp -t "ai-loop.XXXXXX"
}

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
import os
import signal
import subprocess
import sys

seconds = int(sys.argv[1])
cmd = sys.argv[2:]

try:
  proc = subprocess.Popen(cmd, preexec_fn=os.setsid)
  proc.wait(timeout=seconds)
  raise SystemExit(proc.returncode)
except subprocess.TimeoutExpired:
  try:
    os.killpg(proc.pid, signal.SIGTERM)
  except Exception:
    pass
  try:
    proc.wait(timeout=5)
  except Exception:
    try:
      os.killpg(proc.pid, signal.SIGKILL)
    except Exception:
      pass
  raise SystemExit(124)
PY
}

hash_tree() {
  python3 - <<'PY'
import hashlib
import os
import subprocess

state_dir = os.environ.get('STATE_DIR', '.ai-metrics')
ignore_dirs = {'.git', state_dir, 'bin', 'obj', 'node_modules', '__pycache__'}

def should_skip(path: str) -> bool:
  parts = path.split(os.sep)
  return any(part in ignore_dirs for part in parts if part)

def tracked_files():
  try:
    output = subprocess.check_output(['git', 'ls-files'], text=True)
  except Exception:
    output = ''
  files = [line.strip() for line in output.splitlines() if line.strip()]
  if files:
    return files

  files = []
  for dirpath, dirnames, filenames in os.walk('.'):
    dirnames[:] = [d for d in dirnames if d not in ignore_dirs]
    for name in filenames:
      rel = os.path.relpath(os.path.join(dirpath, name), '.')
      if should_skip(rel):
        continue
      files.append(rel)
  return files

h = hashlib.sha1()

for rel_path in sorted(set(tracked_files())):
  try:
    with open(rel_path, 'rb') as f:
      content = f.read()
  except FileNotFoundError:
    continue
  h.update(rel_path.encode('utf-8', errors='replace'))
  h.update(b'\0')
  h.update(content)
  h.update(b'\0')

print(h.hexdigest())
PY
}

file_size_bytes() {
  local path="$1"
  if [ ! -e "$path" ]; then
    echo 0
    return
  fi

  # Prefer GNU stat when available; otherwise use BSD stat (macOS)
  if stat --version >/dev/null 2>&1; then
    stat -c%s "$path" 2>/dev/null || echo 0
  else
    stat -f%z "$path" 2>/dev/null || echo 0
  fi
}

prepare_diff_chunks() {
  local diff_file="$1"
  local output_dir="$STATE_DIR/review_chunks"

  rm -rf "$output_dir"
  mkdir -p "$output_dir"

  if [ ! -s "$diff_file" ]; then
    return 1
  fi

  local size
  size=$(file_size_bytes "$diff_file")

  local chunk_bytes="${COPILOT_DIFF_CHUNK_BYTES:-120000}"

  if [ "$size" -le "$chunk_bytes" ]; then
    cp "$diff_file" "$output_dir/chunk.000"
  else
    split -b "$chunk_bytes" -d "$diff_file" "$output_dir/chunk."
  fi

  find "$output_dir" -type f -name 'chunk.*' -print | sort > "$output_dir/chunks.lst"
}

detect_repo_languages() {
  local output
  if ! output="$(python3 - <<'PY'
import os
import subprocess

ignore_dirs = {'.git', 'node_modules', 'bin', 'obj', '__pycache__', '.ai-metrics'}
ext_map = {
    '.cs': 'csharp',
    '.csproj': 'csharp',
    '.sln': 'csharp',
    '.razor': 'csharp',
    '.cshtml': 'csharp',
    '.ts': 'typescript',
    '.tsx': 'typescript',
    '.js': 'javascript',
    '.jsx': 'javascript',
    '.py': 'python',
    '.sh': 'shell',
    '.bash': 'shell',
    '.ps1': 'powershell',
    '.psm1': 'powershell',
    '.sql': 'sql',
    '.tf': 'terraform',
    '.rb': 'ruby',
    '.go': 'go',
    '.rs': 'rust',
    '.java': 'java',
    '.kt': 'kotlin',
    '.kts': 'kotlin',
    '.swift': 'swift',
    '.php': 'php',
    '.vue': 'vue',
    '.svelte': 'svelte',
    '.html': 'frontend',
    '.css': 'frontend',
    '.md': 'docs',
    '.yaml': 'yaml',
    '.yml': 'yaml',
    '.xml': 'xml'
}

def list_files():
    try:
        out = subprocess.check_output(['git', 'ls-files'], text=True)
        files = [line.strip() for line in out.splitlines() if line.strip()]
        if files:
            return files
    except Exception:
        pass

    files = []
    for root, dirs, filenames in os.walk('.'):
        dirs[:] = [d for d in dirs if d not in ignore_dirs]
        for name in filenames:
            rel = os.path.relpath(os.path.join(root, name), '.')
            if rel.startswith(tuple(f"{d}/" for d in ignore_dirs)):
                continue
            files.append(rel)
    return files

files = list_files()
langs = set()

for rel in files:
    lower = rel.lower()
    _, ext = os.path.splitext(lower)
    if ext and ext in ext_map:
        langs.add(ext_map[ext])

basename_set = {os.path.basename(path) for path in files}
if any(name in basename_set for name in ('package.json', 'tsconfig.json')):
    langs.add('javascript')
if any(rel.endswith(('.csproj', '.sln')) for rel in files):
    langs.add('csharp')

print('\n'.join(sorted(langs)))
PY
)"; then
    DETECTED_LANGUAGES=()
    return 1
  fi

  mapfile -t DETECTED_LANGUAGES <<< "$output"
  return 0
}

add_context_resource() {
  local type="$1"
  local name="$2"
  local key="${type}:${name}"
  if [ -n "${CONTEXT_RESOURCE_REGISTRY[$key]:-}" ]; then
    return
  fi
  CONTEXT_RESOURCE_REGISTRY[$key]=1
  CONTEXT_RESOURCE_QUEUE+=("$key")
}

select_language_contexts() {
  CONTEXT_RESOURCE_REGISTRY=()
  CONTEXT_RESOURCE_QUEUE=()

  local lang
  for lang in "${DETECTED_LANGUAGES[@]}"; do
    case "$lang" in
      csharp)
        # Core C# skills
        add_context_resource "skill" "nuget-manager"
        add_context_resource "instruction" "update-docs-on-code-change"
        add_context_resource "instruction" "csharp-modern"
        add_context_resource "instruction" "dotnet-best-practices"
        ;;
      javascript)
        add_context_resource "skill" "webapp-testing"
        ;;
      typescript)
        add_context_resource "instruction" "typescript-5-es2022"
        add_context_resource "skill" "webapp-testing"
        ;;
      shell)
        add_context_resource "instruction" "shell"
        ;;
      python)
        add_context_resource "instruction" "python"
        ;;
      powershell)
        add_context_resource "instruction" "powershell"
        add_context_resource "instruction" "powershell-pester-5"
        ;;
      rust)
        add_context_resource "instruction" "rust"
        ;;
    esac
  done

  # Blazor/Razor detection - add specific skills
  if find "$PROJECT_DIR" -maxdepth 5 -name "*.razor" -print -quit 2>/dev/null | grep -q .; then
    add_context_resource "instruction" "blazor-components"
    add_context_resource "instruction" "razor-syntax"
    echo "Detected Blazor/Razor files - adding Blazor skills" >&2
  fi

  # MAUI/Catalyst detection
  if find "$PROJECT_DIR" -maxdepth 3 -name "*.csproj" -exec grep -l "net.*-maccatalyst\|net.*-ios\|net.*-android\|Maui" {} \; 2>/dev/null | grep -q .; then
    add_context_resource "instruction" "maui-development"
    echo "Detected MAUI/Catalyst project - adding MAUI skills" >&2
  fi

  if [ -f "$PROJECT_DIR/playwright.config.js" ] || [ -f "$PROJECT_DIR/playwright.config.ts" ]; then
    add_context_resource "skill" "webapp-testing"
  fi

  if [ -f "$PROJECT_DIR/TODO.md" ] || [ -f "$PROJECT_DIR/README.md" ]; then
    add_context_resource "instruction" "update-docs-on-code-change"
  fi
}

# ============================================================
# EMBEDDED SKILL DEFINITIONS FOR POWERSHELL/SHELL
# These are used when remote fetch fails or for offline operation
# ============================================================

get_embedded_skill_content() {
  local type="$1"
  local name="$2"

  case "$type:$name" in
    instruction:powershell)
      cat <<'SKILL_EOF'
---
applyTo: '**/*.ps1,**/*.psm1'
description: 'PowerShell cmdlet and scripting best practices based on Microsoft guidelines'
---

# PowerShell Cmdlet Development Guidelines

## Naming Conventions
- Use Verb-Noun format with approved verbs (Get-Verb)
- Use PascalCase for functions and parameters
- Use singular nouns, avoid abbreviations
- Use full cmdlet names in scripts (avoid aliases)

## Parameter Design
- Use standard parameter names (Path, Name, Force)
- Use [Parameter(Mandatory)] for required params
- Use [ValidateSet] for limited options
- Use [switch] for boolean flags

## Pipeline and Output
- Use ValueFromPipeline for pipeline input
- Return rich objects, not formatted text
- Use Begin/Process/End blocks for streaming
- Implement -PassThru for action cmdlets

## Error Handling
- Use [CmdletBinding(SupportsShouldProcess)] for changes
- Use Write-Verbose for operational details
- Use $PSCmdlet.WriteError() in advanced functions
- Use $PSCmdlet.ThrowTerminatingError() for fatal errors
- Use try/catch with proper ErrorRecord objects

## Documentation
- Include comment-based help (.SYNOPSIS, .DESCRIPTION, .EXAMPLE)
- Use consistent 4-space indentation
- Opening braces on same line as statement
SKILL_EOF
      ;;

    instruction:powershell-pester-5)
      cat <<'SKILL_EOF'
---
applyTo: '**/*.Tests.ps1'
description: 'PowerShell Pester testing best practices based on Pester v5 conventions'
---

# PowerShell Pester v5 Testing Guidelines

## File Structure
- Use *.Tests.ps1 naming pattern
- Put ALL code inside Pester blocks
- Use BeforeAll { . $PSScriptRoot/FunctionName.ps1 } for imports

## Test Hierarchy
- Describe: Top-level grouping by function
- Context: Sub-grouping for scenarios
- It: Individual test cases
- BeforeAll/AfterAll: Setup/teardown once per block
- BeforeEach/AfterEach: Per-test setup/teardown

## Assertions (Should)
- Basic: -Be, -BeExactly, -Not -Be
- Collections: -Contain, -BeIn, -HaveCount
- Strings: -Match, -Like, -BeNullOrEmpty
- Types: -BeOfType, -BeTrue, -BeFalse
- Exceptions: -Throw, -Not -Throw

## Mocking
- Mock CommandName { ScriptBlock }
- Use -ParameterFilter for conditional mocks
- Should -Invoke to verify mock calls
- Mocks scope to containing block

## Data-Driven Tests
- Use -TestCases or -ForEach for parameterized tests
- Use <variablename> in test names for expansion

## Best Practices
- Use AAA pattern: Arrange, Act, Assert
- One assertion per test when possible
- Use descriptive test names
- Avoid aliases in test code
SKILL_EOF
      ;;

    instruction:shell)
      cat <<'SKILL_EOF'
---
description: 'Shell scripting best practices for bash, sh, zsh'
applyTo: '**/*.sh'
---

# Shell Scripting Guidelines

## General Principles
- Generate clean, simple, concise code
- Add comments for understanding
- Use shellcheck for static analysis
- Double-quote variable references ("$var")
- Use modern Bash features when allowed

## Error Handling & Safety
- Always enable set -euo pipefail
- Validate required parameters
- Use trap for cleanup on exit
- Use readonly for immutable values
- Use mktemp for temporary files

## Script Structure
- Start with #!/bin/bash shebang
- Include header comment for purpose
- Define defaults at the top
- Use functions for reusable code
- Keep main flow clean and readable

## Working with JSON/YAML
- Prefer jq for JSON, yq for YAML
- Validate required fields exist
- Quote jq/yq filters
- Treat parser errors as fatal
SKILL_EOF
      ;;

    instruction:update-docs-on-code-change)
      cat <<'SKILL_EOF'
---
description: 'Update documentation when code changes'
applyTo: '**/*.{md,ps1,sh}'
---

# Update Documentation on Code Change

## When to Update
- New features or functionality added
- API or interfaces change
- Breaking changes introduced
- Configuration options modified
- Installation procedures change

## README.md Updates
- Add feature descriptions
- Update installation steps
- Document new CLI commands
- Update configuration examples

## Code Example Synchronization
- Update snippets when signatures change
- Verify examples still work
- Replace outdated patterns

## Best Practices
- Update docs in same commit as code
- Test code examples before committing
- Keep documentation DRY
- Document limitations and edge cases
SKILL_EOF
      ;;

    *)
      return 1
      ;;
  esac

  return 0
}

fetch_context_markdown_with_fallback() {
  local type="$1"
  local name="$2"

  # Try remote fetch first
  local result
  if result="$(fetch_context_markdown "$type" "$name" 2>/dev/null)"; then
    echo "$result"
    return 0
  fi

  # Fall back to embedded content
  local cache_dir="$STATE_DIR/context-cache"
  mkdir -p "$cache_dir"
  local dest="$cache_dir/${type}-${name}.md"

  if get_embedded_skill_content "$type" "$name" > "$dest.tmp" 2>/dev/null; then
    mv "$dest.tmp" "$dest"
    echo "$dest"
    return 0
  fi

  rm -f "$dest.tmp"
  return 1
}

fetch_context_markdown() {
  local type="$1"
  local name="$2"
  local cache_dir="$STATE_DIR/context-cache"
  mkdir -p "$cache_dir"
  local dest="$cache_dir/${type}-${name}.md"

  if [ -f "$dest" ] && [ "${COPILOT_REFRESH_SKILLS:-0}" != "1" ]; then
    echo "$dest"
    return 0
  fi

  local url=""
  case "$type" in
    instruction)
      url="https://raw.githubusercontent.com/github/awesome-copilot/main/instructions/${name}.instructions.md"
      ;;
    skill)
      url="https://raw.githubusercontent.com/github/awesome-copilot/main/skills/${name}/SKILL.md"
      ;;
    *)
      return 1
      ;;
  esac

  if curl -fsSL "$url" -o "$dest.tmp"; then
    mv "$dest.tmp" "$dest"
    echo "$dest"
    return 0
  fi

  rm -f "$dest.tmp"
  return 1
}

render_context_resource() {
  local type="$1"
  local name="$2"
  local path="$3"

  python3 - "$type" "$name" "$path" <<'PY'
import sys
from pathlib import Path

type_id, name_id, path = sys.argv[1:4]
text = Path(path).read_text(encoding='utf-8', errors='replace')

header = name_id.replace('-', ' ').title()
description = ''

if text.startswith('---'):
    parts = text.split('---', 2)
    if len(parts) >= 3:
        front_matter = parts[1].strip()
        body = parts[2]
        meta = {}
        for line in front_matter.splitlines():
            if ':' in line:
                key, value = line.split(':', 1)
                meta[key.strip()] = value.strip().strip("'\"")
        if 'name' in meta:
            header = meta['name']
        description = meta.get('description', '')
        text = body

text = text.strip()
if len(text) > 2000:
    text = text[:2000].rstrip() + "\n[...truncated...]"

title = f"{type_id.title()} - {header}"
blocks = [f"### {title}"]
if description:
    blocks.append(description)
if text:
    blocks.append(text)

print('\n\n'.join(blocks))
PY
}

build_skill_context_block() {
  SKILL_CONTEXT_BLOCK=""
  if [ "${#CONTEXT_RESOURCE_QUEUE[@]}" -eq 0 ]; then
    return 0
  fi

  local key type name file segment
  for key in "${CONTEXT_RESOURCE_QUEUE[@]}"; do
    type="${key%%:*}"
    name="${key#*:}"
    # Use fallback function that tries remote then embedded
    if ! file="$(fetch_context_markdown_with_fallback "$type" "$name" 2>/dev/null)"; then
      echo "WARNING: Unable to fetch context for $key (tried remote and embedded)" >&2
      continue
    fi
    if ! segment="$(render_context_resource "$type" "$name" "$file" 2>/dev/null)"; then
      echo "WARNING: Unable to render context for $key" >&2
      continue
    fi
    if [ -n "$segment" ]; then
      if [ -n "$SKILL_CONTEXT_BLOCK" ]; then
        SKILL_CONTEXT_BLOCK+=$'\n\n'
      fi
      SKILL_CONTEXT_BLOCK+="$segment"
    fi
  done
}

refresh_skill_context() {
  local previous_signature="${CURRENT_CONTEXT_SIGNATURE:-}"

  DETECTED_LANGUAGES=()
  detect_repo_languages || true
  select_language_contexts
  build_skill_context_block

  local new_signature="${DETECTED_LANGUAGES[*]}|${CONTEXT_RESOURCE_QUEUE[*]}"
  CURRENT_CONTEXT_SIGNATURE="$new_signature"

  if [ "$new_signature" != "$previous_signature" ]; then
    if [ "${#DETECTED_LANGUAGES[@]}" -gt 0 ]; then
      echo "Detected languages: ${DETECTED_LANGUAGES[*]}" >&2
    else
      echo "Detected languages: (none)" >&2
    fi

    if [ "${#CONTEXT_RESOURCE_QUEUE[@]}" -gt 0 ]; then
      echo "Active Copilot skills/instructions: ${CONTEXT_RESOURCE_QUEUE[*]}" >&2
    else
      echo "Active Copilot skills/instructions: (none)" >&2
    fi
  fi
}

append_skill_context() {
  local base="$1"
  if [ -z "${SKILL_CONTEXT_BLOCK:-}" ]; then
    printf "%s" "$base"
  else
    printf "%s\n\n=== Skill & Instruction Context ===\n%s" "$base" "$SKILL_CONTEXT_BLOCK"
  fi
}

# ============================================================
# REPO MEMORY SYSTEM — structured memory across iterations
# Store → Compress → Retrieve → Inject
# ============================================================
REPO_MEMORY_SUMMARY=""

initialize_repo_memory() {
  if ! command -v pwsh >/dev/null 2>&1; then
    log "  WARNING: pwsh not available, skipping memory initialization"
    return 0
  fi
  log "Initializing repo memory..."
  pwsh -NoProfile -Command "
    . '$PROJECT_DIR/lib/RepoMemory.ps1'
    Push-Location '$PROJECT_DIR'
    Initialize-RepoMemory '$PROJECT_DIR' | Out-Null
    Pop-Location
  " 2>/dev/null || log "  WARNING: Memory initialization failed (non-fatal)"
}

refresh_repo_memory() {
  if ! command -v pwsh >/dev/null 2>&1; then
    REPO_MEMORY_SUMMARY=""
    return 0
  fi
  REPO_MEMORY_SUMMARY="$(pwsh -NoProfile -Command "
    . '$PROJECT_DIR/lib/RepoMemory.ps1'
    Push-Location '$PROJECT_DIR'
    Update-GitMemory '$PROJECT_DIR' | Out-Null
    Get-MemorySummary
    Pop-Location
  " 2>/dev/null)" || REPO_MEMORY_SUMMARY=""
}

save_run_memory() {
  local iteration="${1:-0}"
  local build_ok="${2:-true}"
  local test_ok="${3:-true}"
  local failures="${4:-}"
  local diff_summary="${5:-}"

  if ! command -v pwsh >/dev/null 2>&1; then return 0; fi

  pwsh -NoProfile -Command "
    . '$PROJECT_DIR/lib/RepoMemory.ps1'
    Push-Location '$PROJECT_DIR'
    Save-RunState -Iteration $iteration -BuildOk \$$build_ok -TestOk \$$test_ok ``
      -Failures @($(printf "'%s'," $failures | sed 's/,$//')) ``
      -DiffSummary '$diff_summary'
    Update-CodeIntel '$PROJECT_DIR'
    Pop-Location
  " 2>/dev/null || true
}

update_memory_heuristics() {
  local failed_files="${1:-}"
  local failed_tests="${2:-}"

  if ! command -v pwsh >/dev/null 2>&1; then return 0; fi
  if [ -z "$failed_files" ] && [ -z "$failed_tests" ]; then return 0; fi

  pwsh -NoProfile -Command "
    . '$PROJECT_DIR/lib/RepoMemory.ps1'
    Push-Location '$PROJECT_DIR'
    Update-Heuristics -FailedFiles @($(printf "'%s'," $failed_files | sed 's/,$//')) ``
      -FailedTests @($(printf "'%s'," $failed_tests | sed 's/,$//'))
    Pop-Location
  " 2>/dev/null || true
}

update_git_memory() {
  if ! command -v pwsh >/dev/null 2>&1; then return 0; fi

  pwsh -NoProfile -Command "
    . '$PROJECT_DIR/lib/RepoMemory.ps1'
    Push-Location '$PROJECT_DIR'
    Update-GitMemory '$PROJECT_DIR' | Out-Null
    Pop-Location
  " 2>/dev/null || true
}

compact_memory() {
  if ! command -v pwsh >/dev/null 2>&1; then return 0; fi

  pwsh -NoProfile -Command "
    . '$PROJECT_DIR/lib/RepoMemory.ps1'
    Push-Location '$PROJECT_DIR'
    Compress-Memory | Out-Null
    Pop-Location
  " 2>/dev/null || true
}

append_memory_context() {
  local base="$1"
  if [ -n "$REPO_MEMORY_SUMMARY" ]; then
    printf "%s\n\n%s" "$base" "$REPO_MEMORY_SUMMARY"
  else
    printf "%s" "$base"
  fi
}

limit_prompt_size() {
  local text="$1"
  local max_chars="${COPILOT_PROMPT_MAX_CHARS:-12000}"

  if [ -z "$max_chars" ] || [ "$max_chars" -le 0 ] 2>/dev/null; then
    printf "%s" "$text"
    return
  fi

  local len=${#text}
  if [ "$len" -le "$max_chars" ]; then
    printf "%s" "$text"
    return
  fi

  local head_len=$(((max_chars * 3) / 4))
  local tail_len=$((max_chars - head_len - 80))
  if [ "$tail_len" -lt 0 ]; then
    tail_len=0
  fi

  local head="${text:0:head_len}"
  local tail=""
  if [ "$tail_len" -gt 0 ]; then
    tail="${text: -tail_len}"
  fi

  printf "%s\n\n[Prompt truncated to %d of %d chars]\n%s" "$head" "$len" "$max_chars" "$tail"
}

copilot_model_is_premium() {
  local model="$1"
  if [ -z "$model" ]; then
    return 1
  fi
  if [ -z "$COPILOT_PREMIUM_MODEL_PATTERN" ]; then
    return 1
  fi
  [[ "$model" =~ $COPILOT_PREMIUM_MODEL_PATTERN ]]
}

copilot_model_is_blacklisted() {
  local model="$1"
  if [ -z "$model" ]; then
    return 1
  fi
  local item
  for item in "${COPILOT_PREMIUM_BLACKLIST[@]:-}"; do
    if [ "$item" = "$model" ]; then
      return 0
    fi
  done
  return 1
}

copilot_model_blacklist_add() {
  local model="$1"
  if [ -z "$model" ]; then
    return 0
  fi
  if copilot_model_is_blacklisted "$model"; then
    return 0
  fi
  COPILOT_PREMIUM_BLACKLIST+=("$model")
}

select_copilot_model() {
  local requested="$1"
  local selected="$requested"

  if [ -z "$selected" ]; then
    selected="$COPILOT_DEFAULT_MODEL"
  fi

  if [ -z "$selected" ]; then
    selected="$COPILOT_FREE_MODEL"
  fi

  if [ -z "$selected" ]; then
    echo ""
    return 0
  fi

  # Prefer free model if the selected model is blacklisted
  if copilot_model_is_blacklisted "$selected"; then
    selected="$COPILOT_FREE_MODEL"
  fi

  # If premium is globally unavailable, avoid premium models
  if [ "$COPILOT_PREMIUM_AVAILABLE" -eq 0 ] && copilot_model_is_premium "$selected"; then
    selected="$COPILOT_FREE_MODEL"
  fi

  echo "$selected"
}

copilot_log_indicates_credit_issue() {
  local log_text="$1"
  if [ -z "$log_text" ]; then
    return 1
  fi

  if [ -z "$COPILOT_CREDIT_ERROR_REGEX" ]; then
    return 1
  fi

  echo "$log_text" | grep -Eiq -- "$COPILOT_CREDIT_ERROR_REGEX"
}

copilot_log_indicates_enablement_needed() {
  local log_text="$1"
  if [ -z "$log_text" ]; then
    return 1
  fi

  if [ -z "$COPILOT_MODEL_ENABLE_ERROR_REGEX" ]; then
    return 1
  fi

  echo "$log_text" | grep -Eiq -- "$COPILOT_MODEL_ENABLE_ERROR_REGEX"
}

run_copilot_cli_with_model() {
  local stage="$1"
  local role="$2"
  local model="$3"
  local prompt="$4"

  local log_file
  log_file="$(mktemp_file)"
  local prompt_file
  prompt_file="$(mktemp_file)"
  printf "%s" "$prompt" > "$prompt_file"
  local prompt_payload
  prompt_payload="$(cat "$prompt_file")"
  trap 'rm -f "${prompt_file:-}"' RETURN

  local stage_label="${stage^^}"
  echo "[$stage_label] ($role) copilot --model $model --yolo" >&2

  COPILOT_LAST_LOG=""

  # Run copilot CLI and capture output
  run_with_timeout "$COPILOT_TIME_LIMIT" "$COPILOT_CMD" --model "$model" --yolo --prompt "$prompt_payload" >"$log_file" 2>&1
  local cmd_status=$?

  # Explicitly treat HTTP 402 as quota exhaustion
  if [ "$cmd_status" -eq 402 ]; then
    if [ -s "$log_file" ]; then
      COPILOT_LAST_LOG="$(cat "$log_file")"
      printf "%s" "$COPILOT_LAST_LOG"
    else
      COPILOT_LAST_LOG=""
    fi
    rm -f "$log_file"
    return 2
  fi

  if [ -s "$log_file" ]; then
    COPILOT_LAST_LOG="$(cat "$log_file")"
    printf "%s" "$COPILOT_LAST_LOG"
  else
    COPILOT_LAST_LOG=""
  fi
  rm -f "$log_file"

  # Detect credit exhaustion messages even when exit code is 0
  if copilot_log_indicates_credit_issue "$COPILOT_LAST_LOG"; then
    return 2
  fi

  # Detect model enablement/entitlement messages (including premium not allowed)
  if copilot_log_indicates_enablement_needed "$COPILOT_LAST_LOG"; then
    return 3
  fi

  # Empty output is suspicious when prompt is non-empty
  if [ -z "$COPILOT_LAST_LOG" ] && [ -n "$prompt_payload" ]; then
    return 4
  fi

  return $cmd_status
}

run_claude_cli_with_model() {
  local stage="$1"
  local role="$2"
  local model="$3"
  local prompt="$4"

  if [ -z "$CLAUDE_CMD" ]; then
    return 1
  fi

  # Check if Claude is already exhausted for today
  if ! claude_available_today; then
    echo "[$stage] Claude tokens exhausted for today. Skipping Claude." >&2
    return 2  # Special return code for exhaustion
  fi

  local log_file
  log_file="$(mktemp_file)"
  local prompt_file
  prompt_file="$(mktemp_file)"
  printf "%s" "$prompt" > "$prompt_file"
  local prompt_payload
  prompt_payload="$(cat "$prompt_file")"
  trap 'rm -f "${prompt_file:-}"' RETURN

  local stage_label="${stage^^}"
  echo "[$stage_label] ($role) claude --model $model $CLAUDE_ARGS" >&2

  CLAUDE_LAST_LOG=""

  run_with_timeout "$COPILOT_TIME_LIMIT" "$CLAUDE_CMD" --model "$model" $CLAUDE_ARGS --print "$prompt_payload" >"$log_file" 2>&1
  local cmd_status=$?

  if [ -s "$log_file" ]; then
    CLAUDE_LAST_LOG="$(cat "$log_file")"
    printf "%s" "$CLAUDE_LAST_LOG"
  else
    CLAUDE_LAST_LOG=""
  fi
  rm -f "$log_file"

  # Check for quota/token exhaustion in output
  if claude_log_indicates_quota_exhaustion "$CLAUDE_LAST_LOG"; then
    mark_claude_exhausted
    return 2  # Signal exhaustion for fallback
  fi

  # Check if it's a quota-related exit code
  if [ "$cmd_status" -eq 402 ] || [ "$cmd_status" -eq 429 ]; then
    mark_claude_exhausted
    return 2
  fi

  # Treat non-zero as failure so fallback engages.
  if [ "$cmd_status" -ne 0 ]; then
    return 1
  fi

  if [ -z "$CLAUDE_LAST_LOG" ] && [ -n "$prompt_payload" ]; then
    return 1
  fi

  return 0
}

run_copilot_with_fallback() {
  local stage="$1"
  local role="$2"
  local prompt="$3"
  local primary_model="$4"

  local claude_status=0
  local copilot_status=0

  # ============================================================
  # TIER 1: Try Claude Code CLI first (if available and not exhausted)
  # ============================================================
  if claude_available_today && [ -n "$CLAUDE_CMD" ]; then
    run_claude_cli_with_model "$stage" "$role" "$CLAUDE_MODEL" "$prompt"
    claude_status=$?

    if [ "$claude_status" -eq 0 ]; then
      return 0  # Success with Claude
    fi

    # If Claude returned exhaustion code (2), it already marked exhausted
    if [ "$claude_status" -eq 2 ]; then
      echo "NOTICE: Claude exhausted. Falling back to Copilot." >&2
    fi
  fi

  # ============================================================
  # TIER 2: Try Copilot Premium (if available and not exhausted)
  # ============================================================
  if copilot_premium_available_today && copilot_model_is_premium "$primary_model"; then
    if run_copilot_cli_with_model "$stage" "$role" "$primary_model" "$prompt"; then
      return 0
    fi

    copilot_status=$?
    local log_text="${COPILOT_LAST_LOG:-}"

    # Credit exhaustion detected: mark premium unavailable
    if copilot_log_indicates_credit_issue "$log_text" || [ "$copilot_status" -eq 2 ]; then
      mark_copilot_premium_exhausted
    fi

    # Model enablement issue: blacklist and mark premium unavailable
    if copilot_log_indicates_enablement_needed "$log_text" || [ "$copilot_status" -eq 3 ]; then
      copilot_model_blacklist_add "$primary_model"
      mark_copilot_premium_exhausted
    fi
  fi

  # ============================================================
  # TIER 3: Copilot Free Model (always available fallback)
  # ============================================================
  if [ -n "$COPILOT_FREE_MODEL" ] && copilot_free_available; then
    echo "NOTICE: Using free model $COPILOT_FREE_MODEL as final fallback." >&2
    if run_copilot_cli_with_model "$stage" "$role" "$COPILOT_FREE_MODEL" "$prompt"; then
      return 0
    fi
    copilot_status=$?

    # Check if free model failed due to quota exhaustion
    if copilot_log_indicates_credit_issue "$COPILOT_LAST_LOG" || [ "$copilot_status" -eq 2 ]; then
      mark_copilot_free_exhausted
    fi
  fi

  # All tiers failed
  echo "WARNING: All agent tiers failed for $stage/$role." >&2
  return $copilot_status
}

run_cli_entry() {
  local stage="$1"
  local role="$2"
  local entry_raw="$3"
  local prompt="$4"

  local entry
  entry="$(trim "$entry_raw")"
  [ -n "$entry" ] || return 0

  local tool="${entry%%:*}"
  local model
  if [[ "$entry" == *":"* ]]; then
    model="${entry#*:}"
  else
    model=""
  fi

  case "$tool" in
    copilot)
      if [ -z "$COPILOT_CMD" ]; then
        echo "WARNING: Copilot CLI not available for entry '$entry'." >&2
        return 1
      fi
      local effective_model
      effective_model="$(select_copilot_model "$model")"
      if [ -z "$effective_model" ]; then
        echo "WARNING: No Copilot model available for '$entry'." >&2
        return 1
      fi
      if ! run_copilot_with_fallback "$stage" "$role" "$prompt" "$effective_model"; then
        echo "WARNING: Copilot command failed for '$entry'." >&2
        return 1
      fi
      ;;
    claude)
      if [ -z "$CLAUDE_CMD" ]; then
        echo "WARNING: Claude CLI not available for entry '$entry'." >&2
        return 1
      fi
      local claude_model="${model:-$CLAUDE_MODEL}"
      if ! run_claude_cli_with_model "$stage" "$role" "$claude_model" "$prompt"; then
        echo "WARNING: Claude command failed for '$entry'." >&2
        return 1
      fi
      ;;
    *)
      echo "WARNING: Unsupported tool '$tool' in entry '$entry'." >&2
      return 1
      ;;
  esac
}

run_pipeline() {
  local stage="$1"
  local role="$2"
  local chain="$3"
  local prompt="$4"

  IFS=',' read -r -a entries <<< "$chain"
  local status=0
  for entry in "${entries[@]}"; do
    if ! run_cli_entry "$stage" "$role" "$entry" "$prompt"; then
      status=1
    fi
  done
  return $status
}

run_builder_prompts() {
  local mode="$1"

  # Refresh repo memory before builders run
  refresh_repo_memory
  local memory_block=""
  if [ -n "$REPO_MEMORY_SUMMARY" ]; then
    memory_block=$'\n\n'"$REPO_MEMORY_SUMMARY"
  fi

  # Bug Fix Builder - picks C-stream items from TODO.md
  local base_bugfix="You are the Bug Fix Builder.
Read TODO.md and pick ONE unchecked item from the C stream (bug fixes & code quality).
Implement the fix with proper error handling and add/update tests.
Mark the item [x] in TODO.md when complete.
IMPORTANT: NEVER read, modify, or create files in the vibe/ folder. It is off-limits.
Do not ask questions. Apply changes directly.${memory_block}"
  local bugfix_prompt
  bugfix_prompt="$(append_skill_context "$base_bugfix")"
  bugfix_prompt="$(limit_prompt_size "$bugfix_prompt")"
  run_pipeline "builder" "bugfix-builder" "$CLAUDE_BUILDER_CHAIN" "$bugfix_prompt" || true

  # Feature Builder - picks D-stream items from TODO.md
  local base_feature="You are the Feature Builder.
Read TODO.md and pick ONE unchecked item from the D stream (new features).
Implement the feature end-to-end with tests and docs.
Mark the item [x] in TODO.md when complete.
IMPORTANT: NEVER read, modify, or create files in the vibe/ folder. It is off-limits.
Do not ask questions. Apply changes directly.${memory_block}"
  local feature_prompt
  feature_prompt="$(append_skill_context "$base_feature")"
  feature_prompt="$(limit_prompt_size "$feature_prompt")"
  run_pipeline "builder" "feature-builder" "$CLAUDE_BUILDER_CHAIN" "$feature_prompt" || true

  # Test Builder - picks E-stream items from TODO.md
  local base_test="You are the Test Builder.
Read TODO.md and pick ONE unchecked item from the E stream (test coverage).
Write comprehensive tests for the specified area.
Mark the item [x] in TODO.md when complete.
IMPORTANT: NEVER read, modify, or create files in the vibe/ folder. It is off-limits.
Do not ask questions. Apply changes directly.${memory_block}"
  local test_prompt
  test_prompt="$(append_skill_context "$base_test")"
  test_prompt="$(limit_prompt_size "$test_prompt")"
  run_pipeline "builder" "test-builder" "$CLAUDE_BUILDER_CHAIN" "$test_prompt" || true

  # General Improver - picks any unchecked item
  local base_improver="You are the Improver.
Read TODO.md and pick ONE unchecked item from ANY stream (C, D, or E).
Implement it fully with tests. Mark the item [x] when complete.
IMPORTANT: NEVER read, modify, or create files in the vibe/ folder. It is off-limits.
Do not ask questions. Apply changes directly.${memory_block}"
  local improver_prompt
  improver_prompt="$(append_skill_context "$base_improver")"
  improver_prompt="$(limit_prompt_size "$improver_prompt")"
  run_pipeline "builder" "improver" "$CLAUDE_BUILDER_CHAIN" "$improver_prompt" || true
}

run_reviewer_prompt() {
  local role="$1"
  local mode="$2"
  local diff_chunk="$3"
  local index="$4"
  local total="$5"

  local base_prompt
  base_prompt="You are the $role.
Current mode: $mode.
"
  if [ -n "$diff_chunk" ] && [ -f "$diff_chunk" ]; then
    base_prompt+="Diff chunk $index of $total:\n\n$(cat "$diff_chunk")\n"
  else
    base_prompt+="No diff chunk available. Inspect the repository directly.\n"
  fi
  base_prompt+=$'- Improve the code.
- Fix bugs.
- Improve tests, including .NET coverage.
- Apply changes directly.
- Do not ask questions.
- NEVER read, modify, or create files in the vibe/ folder. It is off-limits.'

  local reviewer_prompt
  reviewer_prompt="$(append_skill_context "$base_prompt")"
  reviewer_prompt="$(limit_prompt_size "$reviewer_prompt")"

  run_pipeline "review" "$role" "$CLAUDE_REVIEW_CHAIN" "$reviewer_prompt" || true
}

run_backlog_groomer_prompt() {
  local mode="$1"

  local base_prompt
  base_prompt="You are the Backlog Groomer.

Scan the codebase and add new issues to TODO.md:

1. **Find issues**: Search for TODO/FIXME/HACK comments, missing error handling, untested code, security issues.

2. **Add to TODO.md** in the appropriate stream:
   - C stream: Bug fixes (C58, C59...)
   - D stream: New features (D10, D11...)
   - E stream: Test coverage (E27, E28...)

3. **Format**: \`- [ ] **ID — Title** — file.ps1 L##\`

4. **Mark done**: If code shows a task is complete, mark it \`[x]\`.

Rules:
- NEVER scan, reference, or add issues about files in the vibe/ folder. It is off-limits.
- Only scan files in: lib/, agents/, scripts/, tests/, and root .ps1 files.
- Only add REAL issues with file:line evidence
- No duplicates
- Sequential IDs within each stream
- Do not ask questions. Apply changes directly."

  local groomer_prompt
  groomer_prompt="$(append_skill_context "$base_prompt")"
  groomer_prompt="$(limit_prompt_size "$groomer_prompt")"

  run_pipeline "review" "backlog-groomer" "$CLAUDE_REVIEW_CHAIN" "$groomer_prompt" || true
}

wait_for_tmux_completion() {
  local session="$1"
  local timeout="$2"
  local start now elapsed last_update
  start="$(date +%s)"
  last_update=0

  while tmux has-session -t "$session" >/dev/null 2>&1; do
    # If all panes have exited (pane_dead=1), stop immediately.
    if ! tmux list-panes -t "$session" -F '#{pane_dead}' | grep -q 0; then
      tmux kill-session -t "$session" >/dev/null 2>&1 || true
      return 0
    fi

    now="$(date +%s)"
    elapsed=$((now - start))

    # Log progress every 30 seconds
    if [ $((elapsed - last_update)) -ge 30 ]; then
      local alive_panes
      alive_panes=$(tmux list-panes -t "$session" -F '#{pane_dead}' 2>/dev/null | grep -c "0" || echo "0")
      log "  ⏳ Builders running... ${elapsed}s elapsed, $alive_panes panes active"
      last_update=$elapsed
    fi

    if [ "$timeout" -gt 0 ] && [ "$elapsed" -ge "$timeout" ]; then
      log "WARNING: tmux session '$session' exceeded ${timeout}s; terminating."
      tmux kill-session -t "$session" >/dev/null 2>&1 || true
      return 1
    fi

    sleep 2
  done

  return 0
}

run_interactive_tmux() {
  local mode="$1"

  local tmux_model
  if [ "$COPILOT_PREMIUM_AVAILABLE" -eq 1 ]; then
    tmux_model="$(select_copilot_model "$COPILOT_DEFAULT_MODEL")"
  else
    tmux_model="$COPILOT_FREE_MODEL"
  fi
  if [ -z "$tmux_model" ]; then
    tmux_model="$COPILOT_FREE_MODEL"
  fi

  # Determine how many agents to run based on available memory
  local agent_count
  agent_count=$(get_recommended_agent_count)
  local available_mem
  available_mem=$(get_available_memory_mb)
  log_progress "MEMORY" "Available: ${available_mem}MB, running $agent_count agents"

  # Refresh repo memory and build memory block for injection
  refresh_repo_memory
  local mem_ctx=""
  if [ -n "$REPO_MEMORY_SUMMARY" ]; then
    mem_ctx=$'\n\n'"$REPO_MEMORY_SUMMARY"
  fi

  local pane_prompts=(
    "You are the Bug Fix Builder. Read TODO.md and pick ONE unchecked C-stream item (bug fix). Implement it with tests. Mark [x] when done. Do not ask questions. Apply changes directly.${mem_ctx}"
    "You are the Feature Builder. Read TODO.md and pick ONE unchecked D-stream item (new feature). Implement it with tests. Mark [x] when done. Do not ask questions. Apply changes directly.${mem_ctx}"
    "You are the Test Builder. Read TODO.md and pick ONE unchecked E-stream item (test coverage). Write the tests. Mark [x] when done. Do not ask questions. Apply changes directly.${mem_ctx}"
    "You are the Improver. Read TODO.md and pick ONE unchecked item from ANY stream. Implement it with tests. Mark [x] when done. Do not ask questions. Apply changes directly.${mem_ctx}"
    "You are the Backlog Groomer. Scan codebase for issues. Add new C/D/E items to TODO.md with file:line evidence. Mark completed items [x]. Do not ask questions. Apply changes directly.${mem_ctx}"
  )

  # Limit prompts array to agent_count (prioritize Bug Fix, Feature, Backlog Groomer)
  if [ "$agent_count" -lt 5 ]; then
    local reduced_prompts=()
    # Priority order when memory-constrained: Bug Fix (0), Feature (1), Backlog Groomer (4)
    if [ "$agent_count" -ge 1 ]; then reduced_prompts+=("${pane_prompts[0]}"); fi
    if [ "$agent_count" -ge 2 ]; then reduced_prompts+=("${pane_prompts[1]}"); fi
    if [ "$agent_count" -ge 3 ]; then reduced_prompts+=("${pane_prompts[4]}"); fi
    if [ "$agent_count" -ge 4 ]; then reduced_prompts+=("${pane_prompts[2]}"); fi
    pane_prompts=("${reduced_prompts[@]}")
    log "  Reduced agent set: ${#pane_prompts[@]} agents (memory-constrained mode)"
  fi

  tmux kill-session -t "$TMUX_SESSION" >/dev/null 2>&1 || true
  tmux new-session -d -s "$TMUX_SESSION" -c "$PROJECT_DIR"
  tmux set-option -t "$TMUX_SESSION" mouse on >/dev/null 2>&1 || true

  # Dynamically create panes based on agent count
  local num_agents=${#pane_prompts[@]}
  local panes=("$TMUX_SESSION:0.0")

  if [ "$num_agents" -ge 2 ]; then
    tmux split-window -h -t "$TMUX_SESSION:0.0"
    panes+=("$TMUX_SESSION:0.1")
  fi
  if [ "$num_agents" -ge 3 ]; then
    tmux split-window -v -t "$TMUX_SESSION:0.0"
    panes=("$TMUX_SESSION:0.0" "$TMUX_SESSION:0.1" "$TMUX_SESSION:0.2")
  fi
  if [ "$num_agents" -ge 4 ]; then
    tmux split-window -v -t "$TMUX_SESSION:0.2"
    panes=("$TMUX_SESSION:0.0" "$TMUX_SESSION:0.1" "$TMUX_SESSION:0.2" "$TMUX_SESSION:0.3")
  fi
  if [ "$num_agents" -ge 5 ]; then
    tmux split-window -v -t "$TMUX_SESSION:0.3"
    panes=("$TMUX_SESSION:0.0" "$TMUX_SESSION:0.1" "$TMUX_SESSION:0.2" "$TMUX_SESSION:0.3" "$TMUX_SESSION:0.4")
  fi
  tmux select-layout tiled

  # Determine which CLI to use - Claude first, Copilot as fallback
  local primary_cmd="$CLAUDE_CMD"
  local primary_args="--model $CLAUDE_MODEL $CLAUDE_ARGS --print"
  local fallback_cmd="$COPILOT_CMD"
  local fallback_args="--model ${tmux_model} --yolo --prompt"
  local use_claude=1

  if [ -z "$CLAUDE_CMD" ] || [ -f "$CLAUDE_EXHAUSTED_FILE" ]; then
    use_claude=0
    primary_cmd="$COPILOT_CMD"
    primary_args="--model ${tmux_model} --yolo --prompt"
  fi

  for i in "${!panes[@]}"; do
    local pane="${panes[$i]}"
    local prompt
    prompt="$(append_skill_context "${pane_prompts[$i]}")"
    prompt="$(limit_prompt_size "$prompt")"
    local prompt_file
    prompt_file="$(mktemp_file)"
    printf "%s" "$prompt" > "$prompt_file"
    local prompt_file_escaped primary_cmd_escaped fallback_cmd_escaped
    printf -v prompt_file_escaped %q "$prompt_file"
    printf -v primary_cmd_escaped %q "$primary_cmd"
    printf -v fallback_cmd_escaped %q "$fallback_cmd"

  local cmd
  if [ "$use_claude" -eq 1 ]; then
    # Claude-first with Copilot fallback
    cmd="set +H;
prompt=\$(cat $prompt_file_escaped);

echo '[BUILDER] Trying Claude CLI first...';
$primary_cmd_escaped $primary_args \"\$prompt\";
status=\$?;

if [ \"\$status\" -ne 0 ]; then
  echo '[BUILDER] Claude failed (status='\$status'). Falling back to Copilot...';
  $fallback_cmd_escaped $fallback_args \"\$prompt\";
  status=\$?;

  if [ \"\$status\" -eq 402 ]; then
    echo '[BUILDER] Quota exceeded. Retrying with free model...';
    $fallback_cmd_escaped --model ${COPILOT_FREE_MODEL} --yolo --prompt \"\$prompt\";
    status=\$?;
  fi
fi

rm -f $prompt_file_escaped;
exit \$status"
  else
    # Copilot only (Claude unavailable)
    cmd="set +H;
prompt=\$(cat $prompt_file_escaped);

$primary_cmd_escaped $primary_args \"\$prompt\";
status=\$?;

if [ \"\$status\" -eq 402 ]; then
  echo 'Quota exceeded. Retrying with free model...';
  $fallback_cmd_escaped --model ${COPILOT_FREE_MODEL} --yolo --prompt \"\$prompt\";
  status=\$?;
fi

rm -f $prompt_file_escaped;
exit \$status"
  fi

    printf -v cmd_escaped %q "$cmd"
    tmux send-keys -t "$pane" "bash -lc $cmd_escaped" C-m
  done

  # In fully automated mode (default), run detached and wait for completion.
  # Set TMUX_ATTACH=1 to attach interactively instead.
  if [ "${TMUX_ATTACH:-0}" -eq 1 ] && [ -t 1 ]; then
    tmux attach-session -t "$TMUX_SESSION"
  else
    log "Builders running in tmux session '$TMUX_SESSION' (detached)"
  fi

  log "Waiting for builders to complete (timeout: ${TMUX_TIME_LIMIT}s)..."
  wait_for_tmux_completion "$TMUX_SESSION" "$TMUX_TIME_LIMIT" || true
  log "Builders finished"
}

checkout_main_branch() {
  # Stash any uncommitted changes to avoid checkout conflicts
  local stash_needed=0
  if ! git diff --quiet || ! git diff --cached --quiet; then
    stash_needed=1
    log "Stashing uncommitted changes before checkout..."
    git stash push -m "ai-loop-auto-stash-$(date +%s)" || true
  fi

  if git rev-parse --verify "$MAIN_BRANCH" >/dev/null 2>&1; then
    git checkout "$MAIN_BRANCH"
  elif git rev-parse --verify "origin/$MAIN_BRANCH" >/dev/null 2>&1; then
    git checkout -b "$MAIN_BRANCH" "origin/$MAIN_BRANCH"
    git branch --set-upstream-to="origin/$MAIN_BRANCH" "$MAIN_BRANCH" || true
  else
    git checkout -b "$MAIN_BRANCH"
  fi

  # Sync with remote - handle diverged branches
  git fetch origin "$MAIN_BRANCH" 2>/dev/null || true
  if git rev-parse --verify "origin/$MAIN_BRANCH" >/dev/null 2>&1; then
    # Check if branches have diverged
    local local_commit remote_commit base_commit
    local_commit=$(git rev-parse "$MAIN_BRANCH" 2>/dev/null || echo "")
    remote_commit=$(git rev-parse "origin/$MAIN_BRANCH" 2>/dev/null || echo "")

    if [ -n "$local_commit" ] && [ -n "$remote_commit" ] && [ "$local_commit" != "$remote_commit" ]; then
      base_commit=$(git merge-base "$MAIN_BRANCH" "origin/$MAIN_BRANCH" 2>/dev/null || echo "")

      if [ "$base_commit" = "$remote_commit" ]; then
        # Local is ahead - nothing to pull
        log "Local $MAIN_BRANCH is ahead of origin - no pull needed"
      elif [ "$base_commit" = "$local_commit" ]; then
        # Remote is ahead - fast-forward
        log "Fast-forwarding $MAIN_BRANCH to origin"
        git pull --ff-only origin "$MAIN_BRANCH" || true
      else
        # Branches have diverged - rebase local onto remote
        log "Branches diverged - rebasing local changes onto origin/$MAIN_BRANCH"
        if ! git rebase "origin/$MAIN_BRANCH"; then
          log "WARNING: Rebase failed, aborting and forcing reset to origin"
          git rebase --abort 2>/dev/null || true
          echo "- [ ] Git rebase conflict: local $MAIN_BRANCH diverged from origin - local commits were discarded, review needed" >> TODO.md
          git reset --hard "origin/$MAIN_BRANCH"
        fi
      fi
    fi
  fi

  # Restore stashed changes if we stashed them
  if [ "$stash_needed" -eq 1 ]; then
    log "Restoring stashed changes..."
    if ! git stash pop; then
      log "Stash pop failed - force-applying stashed changes..."
      # stash pop can fail without starting a merge (e.g. "local changes would
      # be overwritten").  Force-apply the stash contents over the working tree.
      git checkout stash@{0} -- . 2>/dev/null || true
      git add -A
      if ! git diff --cached --quiet; then
        if ! git commit -m "Auto-restore stashed changes after rebase"; then
          log "ERROR: Could not commit stash changes"
          echo "- [ ] Git stash conflict needs manual resolution (stash@{0})" >> TODO.md
          echo "stability" > "$FORCED_MODE_FILE"
        fi
      fi
      git stash drop 2>/dev/null || true
    fi
  fi
}

ensure_repo() {
  if [ ! -d ".git" ]; then
    if [ -z "$(ls -A . 2>/dev/null || true)" ]; then
      if [ -n "$REPO_URL" ]; then
        echo "Empty directory, cloning repository..."
        git clone "$REPO_URL" .
      else
        echo "ERROR: No git repository detected and REPO_URL is undefined." >&2
        exit 1
      fi
    else
      echo "ERROR: No git repository detected in $PROJECT_DIR." >&2
      if [ -n "$REPO_URL" ]; then
        echo "Clone $REPO_URL or run the script from within the repository." >&2
      else
        echo "Initialize a git repository in $PROJECT_DIR or set REPO_URL before rerunning." >&2
      fi
      exit 1
    fi
  fi
}

run_build() {
  # PowerShell project: validate syntax
  if [ "$IS_POWERSHELL_PROJECT" -eq 1 ]; then
    echo "INFO: PowerShell project detected; validating script syntax." >&2
    if ! command -v pwsh &>/dev/null; then
      echo "INFO: pwsh not available; skipping PowerShell syntax validation." >&2
      return 0
    fi
    local ps1_errors=0
    while IFS= read -r ps1_file; do
      if ! pwsh -NoProfile -Command "try { \$null = [System.Management.Automation.Language.Parser]::ParseFile('$ps1_file', [ref]\$null, [ref]\$null) } catch { exit 1 }" 2>/dev/null; then
        echo "ERROR: Syntax error in $ps1_file" >&2
        ps1_errors=$((ps1_errors + 1))
      fi
    done < <(find "$PROJECT_DIR" -name '*.ps1' -not -path '*/node_modules/*' -not -path '*/.git/*' -print)
    if [ "$ps1_errors" -gt 0 ]; then
      return 1
    fi
    echo "INFO: All PowerShell scripts passed syntax validation." >&2
    return 0
  fi

  # .NET project build
  if [ -z "$PROJECT_PATH" ] || [ ! -f "$PROJECT_PATH" ]; then
    echo "INFO: No project path configured; skipping dotnet build." >&2
    return 0
  fi

  # Skip MAUI app build on Linux without Android SDK - tests are what matter
  if [[ "$(uname)" == "Linux" ]] && [ -z "${ANDROID_HOME:-}" ] && [ -z "${AndroidSdkDirectory:-}" ]; then
    if grep -q "UseMaui" "$PROJECT_PATH" 2>/dev/null; then
      echo "INFO: MAUI project on Linux without Android SDK; skipping main app build (tests will still run)." >&2
      return 0
    fi
  fi

  local tfm_args=""
  if [ -n "$DOTNET_TARGET_FRAMEWORK" ]; then
    tfm_args="-f $DOTNET_TARGET_FRAMEWORK"
  fi

  "$DOTNET_CMD" build "$PROJECT_PATH" -c "$DOTNET_CONFIGURATION" $tfm_args --no-restore
}

run_tests() {
  # PowerShell project: run Pester tests if available, or run test scripts
  if [ "$IS_POWERSHELL_PROJECT" -eq 1 ]; then
    # Check for Pester tests
    local pester_tests
    pester_tests=$(find "$PROJECT_DIR" -name '*.Tests.ps1' -o -name '*Test*.ps1' 2>/dev/null | grep -v node_modules | head -5)
    if [ -n "$pester_tests" ]; then
      echo "INFO: Running Pester tests..." >&2
      if command -v pwsh >/dev/null 2>&1; then
        pwsh -NoProfile -Command "Invoke-Pester -Path '$PROJECT_DIR' -PassThru -Output Detailed" || return 1
      else
        echo "INFO: pwsh not available; skipping Pester tests." >&2
      fi
    fi

    # Run agent fallback tests if present
    if [ -x "$PROJECT_DIR/scripts/test-agent-fallback.sh" ]; then
      echo "INFO: Running agent fallback tests..." >&2
      bash "$PROJECT_DIR/scripts/test-agent-fallback.sh" || return 1
    fi

    echo "INFO: PowerShell tests completed." >&2
    return 0
  fi

  # .NET project tests
  local has_test_project=0
  while IFS= read -r csproj; do
    if grep -q "<IsTestProject>true</IsTestProject>" "$csproj" 2>/dev/null || [[ "$csproj" == *Tests.csproj ]]; then
      has_test_project=1
      break
    fi
  done < <(find "$PROJECT_DIR" -name '*.csproj' -print)

  if [ "$has_test_project" -eq 0 ]; then
    echo "INFO: No test projects detected; skipping dotnet test." >&2
    return 0
  fi

  local test_target=""
  if [ -n "$SOLUTION_PATH" ] && [ -f "$SOLUTION_PATH" ]; then
    test_target="$SOLUTION_PATH"
  elif [ -n "$PROJECT_PATH" ] && [ -f "$PROJECT_PATH" ]; then
    test_target="$PROJECT_PATH"
  else
    echo "INFO: Tests detected but no solution/project target found; skipping dotnet test." >&2
    return 0
  fi

  local tfm_args=""
  if [ -n "$DOTNET_TARGET_FRAMEWORK" ]; then
    tfm_args="-p:TargetFramework=$DOTNET_TARGET_FRAMEWORK"
  fi

  "$DOTNET_CMD" test "$test_target" -c "$DOTNET_CONFIGURATION" $tfm_args --no-build
}

push_main_branch() {
  if [ "${GIT_AUTO_PUSH_MAIN:-1}" -ne 1 ]; then
    return 0
  fi

  local remote="${GIT_PUSH_REMOTE:-origin}"
  local branch="$MAIN_BRANCH"

  if ! git rev-parse --verify "$branch" >/dev/null 2>&1; then
    echo "WARNING: Cannot push; branch '$branch' not found." >&2
    return 0
  fi

  if ! git remote get-url "$remote" >/dev/null 2>&1; then
    echo "WARNING: Cannot push; remote '$remote' not found." >&2
    return 0
  fi

  git fetch "$remote" "$branch" >/dev/null 2>&1 || true

  if git rev-parse --verify "$remote/$branch" >/dev/null 2>&1; then
    git branch --set-upstream-to="$remote/$branch" "$branch" >/dev/null 2>&1 || true
  fi

  if git rev-parse --verify "$remote/$branch" >/dev/null 2>&1; then
    if ! git merge-base --is-ancestor "$remote/$branch" "$branch"; then
      echo "WARNING: $branch is behind $remote/$branch; attempting fast-forward before push." >&2
      if ! git pull --ff-only "$remote" "$branch"; then
        echo "WARNING: Fast-forward pull failed; skipping push to avoid non-FF." >&2
        return 1
      fi
    fi
  fi

  if git config --get "branch.$branch.remote" >/dev/null 2>&1; then
    if ! git push "$remote" "$branch"; then
      echo "WARNING: git push failed for $remote/$branch." >&2
      return 1
    fi
  else
    if ! git push -u "$remote" "$branch"; then
      echo "WARNING: git push (set upstream) failed for $remote/$branch." >&2
      return 1
    fi
  fi

  return 0
}

ensure_state_dir

# Reset daily quota flags at script start
reset_daily_quota_flags
log_agent_status

if [ "${AI_LOOP_RESET_START_TIME:-0}" = "1" ]; then
  rm -f "$START_TIME_FILE"
fi

# Force reset quota flags if requested
if [ "${AI_LOOP_RESET_QUOTA:-0}" = "1" ]; then
  echo "Resetting all quota flags..." >&2
  rm -f "$CLAUDE_EXHAUSTED_FILE" "$COPILOT_PREMIUM_EXHAUSTED_FILE"
  CURRENT_AGENT="claude"
  log_agent_status
fi

ensure_state_dir

run_self_test() {
  echo "Running AI loop self-test (Claude-first fallback)..."

  local prev_claude_cmd="$CLAUDE_CMD"
  local prev_copilot_cmd="$COPILOT_CMD"
  local prev_claude_args="$CLAUDE_ARGS"
  local prev_time_limit="$COPILOT_TIME_LIMIT"

  CLAUDE_CMD="/bin/true"
  CLAUDE_ARGS=""
  CLAUDE_MODEL="claude-selftest"
  COPILOT_CMD="/bin/true"
  COPILOT_FREE_MODEL="copilot-free-selftest"
  COPILOT_TIME_LIMIT=5

  if ! run_copilot_with_fallback "builder" "selftest" "self-test prompt" "${COPILOT_DEFAULT_MODEL:-gpt-5.2}"; then
    echo "Self-test failed: fallback chain did not succeed." >&2
    return 1
  fi

  CLAUDE_CMD="$prev_claude_cmd"
  COPILOT_CMD="$prev_copilot_cmd"
  CLAUDE_ARGS="$prev_claude_args"
  COPILOT_TIME_LIMIT="$prev_time_limit"

  echo "Self-test passed."
}

if [ "${AI_LOOP_RUN_TESTS_FIRST:-1}" -eq 1 ]; then
  if ! run_tests; then
    echo "Pre-flight tests failed; aborting." >&2
    exit 1
  fi
fi

if [ "${AI_LOOP_SELFTEST:-0}" -eq 1 ]; then
  run_self_test || exit 1
  exit 0
fi

# ----------------------------
# Pre-flight: Verify Copilot CLI works
# ----------------------------
run_copilot_startup_check() {
  local test_prompt="Say OK"
  local test_timeout=30
  local test_output

  echo "Running Copilot CLI startup check..." >&2

  if [ -z "$COPILOT_CMD" ]; then
    echo "WARNING: Copilot CLI not available, skipping check." >&2
    return 0
  fi

  local tmpfile
  tmpfile="$(mktemp_file)"

  if run_with_timeout "$test_timeout" "$COPILOT_CMD" --model "$COPILOT_FREE_MODEL" --yolo --prompt "$test_prompt" >"$tmpfile" 2>&1; then
    echo "✅ Copilot CLI responded successfully." >&2
    rm -f "$tmpfile"
    return 0
  fi

  local status=$?
  echo "❌ Copilot CLI check failed (exit $status). Output:" >&2
  cat "$tmpfile" >&2
  rm -f "$tmpfile"
  return 1
}

if [ "${AI_LOOP_SKIP_COPILOT_CHECK:-0}" != "1" ]; then
  if ! run_copilot_startup_check; then
    echo "ERROR: Copilot CLI pre-flight check failed. Fix the issue or set AI_LOOP_SKIP_COPILOT_CHECK=1 to bypass." >&2
    exit 1
  fi
fi

if [ "${AI_LOOP_DISABLE_WALLCLOCK_LIMIT:-0}" != "1" ]; then
  START_TIME="$(cat "$START_TIME_FILE" 2>/dev/null || echo "")"
  if [ -n "$START_TIME" ]; then
    NOW="$(date +%s)"
    ELAPSED_HOURS="$(((NOW - START_TIME) / 3600))"
    if [ "$ELAPSED_HOURS" -ge "$MAX_WALL_HOURS" ]; then
      mkdir -p "$STATE_DIR"
      log_progress "DONE" "Max wall-clock time reached ($ELAPSED_HOURS h >= $MAX_WALL_HOURS h)"
      log_status "Stopped - Wall clock limit"
      echo "Max wall-clock time reached ($ELAPSED_HOURS h >= $MAX_WALL_HOURS h). Stopping."
      echo "To reset: rm -f '$START_TIME_FILE' (or run: AI_LOOP_RESET_START_TIME=1 ./ai-autonomous-loop-macos-copilot.sh)"
      echo "To disable: AI_LOOP_DISABLE_WALLCLOCK_LIMIT=1 ./ai-autonomous-loop-macos-copilot.sh"
      echo "To increase: MAX_WALL_HOURS=999 ./ai-autonomous-loop-macos-copilot.sh"
      exit 0
    fi
  fi
fi

ensure_repo

[ -f TODO.md ] || echo "# TODO" > TODO.md

# Initialize repo memory system (scan project structure, build code intel, capture git state)
initialize_repo_memory
update_git_memory

if [ -n "$PROJECT_PATH" ] && [ -f "$PROJECT_PATH" ]; then
  # Skip MAUI project restore on Linux without mobile SDKs - iOS/Android workloads unavailable
  if [[ "$(uname)" == "Linux" ]] && [ -z "${ANDROID_HOME:-}" ] && [ -z "${AndroidSdkDirectory:-}" ]; then
    if grep -q "UseMaui" "$PROJECT_PATH" 2>/dev/null; then
      echo "INFO: MAUI project on Linux without mobile SDKs; skipping main app restore (tests will still run)." >&2
    else
      restore_tfm_args=""
      if [ -n "$DOTNET_TARGET_FRAMEWORK" ]; then
        restore_tfm_args="-p:TargetFramework=$DOTNET_TARGET_FRAMEWORK"
      fi
      if ! "$DOTNET_CMD" restore "$PROJECT_PATH" $restore_tfm_args; then
        echo "dotnet restore failed. Investigate .NET workload availability before rerunning." >&2
        exit 1
      fi
    fi
  else
    restore_tfm_args=""
    if [ -n "$DOTNET_TARGET_FRAMEWORK" ]; then
      restore_tfm_args="-p:TargetFramework=$DOTNET_TARGET_FRAMEWORK"
    fi
    if ! "$DOTNET_CMD" restore "$PROJECT_PATH" $restore_tfm_args; then
      echo "dotnet restore failed. Investigate .NET workload availability before rerunning." >&2
      exit 1
    fi
  fi
elif [ -n "$PROJECT_PATH" ]; then
  echo "WARNING: Project path '$PROJECT_PATH' not found; skipping dotnet restore." >&2
fi

checkout_main_branch

ensure_git_identity

# Restore iteration count from previous run (if restarted for memory cleanup)
if [ -f "$STATE_DIR/iteration_count.txt" ]; then
  ITER=$(cat "$STATE_DIR/iteration_count.txt" 2>/dev/null || echo "1")
  log "Resumed from iteration $ITER (script restart for memory cleanup)"
else
  ITER=1
fi
ensure_state_dir
current_hash="$(hash_tree)"
echo "$current_hash" > "$LAST_HASH_FILE"
echo 0 > "$STAGNANT_COUNT_FILE"

# Background mode: fork the loop and tail the log
# Set AI_LOOP_FOREGROUND=1 to disable this behavior
if [ "${AI_LOOP_FOREGROUND:-0}" != "1" ] && [ "${TMUX_ATTACH:-0}" != "1" ]; then
  # Initialize log file header
  echo "" >> "$LOG_FILE"
  {
    echo "=============================================="
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] AI AUTONOMOUS LOOP STARTED"
    echo "=============================================="
    echo "Project: $PROJECT_DIR"
    echo "PID: $$"
    echo "Log file: $LOG_FILE"
    echo "Status file: $STATUS_FILE"
    echo "Tmux session: $TMUX_SESSION"
    echo "=============================================="
  } >> "$LOG_FILE"

  echo ""
  echo "🚀 AI Loop starting in background mode..."
  echo ""
  echo "   Log file:    $LOG_FILE"
  echo "   Status:      $STATUS_FILE"
  echo "   Tmux:        tmux attach -t $TMUX_SESSION"
  echo ""
  echo "   Ctrl+C to stop monitoring (loop keeps running)"
  echo "   To stop loop: kill \$(cat $STATE_DIR/loop.pid)"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # Export vars needed by the backgrounded loop
  export AI_LOOP_FOREGROUND=1
  export ITER LOG_FILE STATUS_FILE STATE_DIR PROJECT_DIR

  # Start the loop in background
  nohup "$SCRIPT_DIR/$(basename "$0")" >> "$LOG_FILE" 2>&1 &
  LOOP_PID=$!
  echo "$LOOP_PID" > "$STATE_DIR/loop.pid"

  # Give it a moment to start
  sleep 1

  # Tail the log - Ctrl+C stops tail but not the loop
  trap 'echo ""; echo "Monitoring stopped. Loop continues (PID: $LOOP_PID)"; echo "Stop loop: kill $LOOP_PID"; exit 0' INT
  tail -f "$LOG_FILE"
  exit 0
fi

# Initialize log file (foreground mode)
echo "" >> "$LOG_FILE"
log "=============================================="
log "AI AUTONOMOUS LOOP STARTED (foreground)"
log "=============================================="
log "Project: $PROJECT_DIR"
log "PID: $$"
log "Log file: $LOG_FILE"
log "=============================================="

# Save PID for external control
echo "$$" > "$STATE_DIR/loop.pid"

# Cleanup on exit
cleanup_loop() {
  log_status "Stopped"
  log "Loop terminated (PID $$)"
  rm -f "$STATE_DIR/loop.pid"
}
trap cleanup_loop EXIT

# ============================================================
# ERROR RECOVERY SYSTEM
# Captures errors, feeds to Claude for resolution, commits fixes
# ============================================================

ERROR_LOG_FILE="$STATE_DIR/last_error.log"
ERROR_CONTEXT_FILE="$STATE_DIR/error_context.txt"
MAX_AUTO_FIX_ATTEMPTS="${MAX_AUTO_FIX_ATTEMPTS:-3}"
AUTO_FIX_ATTEMPT=0

capture_error_context() {
  local error_msg="$1"
  local error_line="$2"
  local error_func="$3"

  {
    echo "=== ERROR CAPTURED ==="
    echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Error: $error_msg"
    echo "Line: $error_line"
    echo "Function: $error_func"
    echo ""
    echo "=== GIT STATUS ==="
    git status 2>&1 || echo "(git status failed)"
    echo ""
    echo "=== RECENT COMMITS ==="
    git log --oneline -5 2>&1 || echo "(git log failed)"
    echo ""
    echo "=== UNCOMMITTED CHANGES ==="
    git diff --stat 2>&1 || echo "(no changes)"
    echo ""
    echo "=== RECENT LOG ENTRIES ==="
    tail -50 "$LOG_FILE" 2>/dev/null || echo "(no log)"
  } > "$ERROR_CONTEXT_FILE"
}

commit_all_changes() {
  local msg="$1"
  if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]; then
    git add -A
    git commit -m "$msg" || true
    log "Committed: $msg"
    return 0
  fi
  return 1
}

push_all_changes() {
  local remote="${GIT_PUSH_REMOTE:-origin}"
  local branch
  branch="$(git rev-parse --abbrev-ref HEAD)"

  # Try to push, handling conflicts
  if ! git push "$remote" "$branch" 2>&1; then
    log "Push failed, attempting pull --rebase..."
    if git pull --rebase "$remote" "$branch" 2>&1; then
      git push "$remote" "$branch" 2>&1 || true
    else
      log "Pull --rebase failed, trying merge strategy..."
      git rebase --abort 2>/dev/null || true
      git pull --no-rebase -X theirs "$remote" "$branch" 2>&1 || true
      git push "$remote" "$branch" 2>&1 || true
    fi
  fi
}

resolve_error_with_claude() {
  local error_context
  error_context="$(cat "$ERROR_CONTEXT_FILE" 2>/dev/null || echo "No error context available")"

  local fix_prompt="You are an autonomous error resolver. The AI loop script has failed.

=== ERROR CONTEXT ===
$error_context

=== INSTRUCTIONS ===
1. Analyze the error and determine the root cause
2. Fix any issues in the codebase that caused this error
3. If it's a git conflict or sync issue, resolve it by:
   - Committing any uncommitted changes
   - Pulling latest changes with conflict resolution
   - Pushing the fixes
4. If it's a code issue, fix the code directly
5. Do not ask questions - apply fixes directly
6. Focus on making the loop able to continue

The goal is to make the script able to restart successfully."

  log "Calling Claude to resolve error (attempt $AUTO_FIX_ATTEMPT)..."

  if [ -n "$CLAUDE_CMD" ]; then
    local fix_output
    fix_output="$(run_with_timeout 300 "$CLAUDE_CMD" --model "$CLAUDE_MODEL" $CLAUDE_ARGS --print "$fix_prompt" 2>&1)" || true
    echo "$fix_output" >> "$LOG_FILE"

    # Commit any fixes Claude made
    if commit_all_changes "Auto-fix: Error resolution attempt $AUTO_FIX_ATTEMPT"; then
      push_all_changes
      return 0
    fi
  else
    log "Claude not available for error resolution"
  fi

  return 1
}

handle_loop_error() {
  local error_msg="${1:-Unknown error}"
  local error_line="${2:-unknown}"
  local error_func="${3:-unknown}"

  log_progress "ERROR" "Loop failed: $error_msg (line $error_line)"
  log_status "Error - Attempting auto-recovery"

  # Save error context
  capture_error_context "$error_msg" "$error_line" "$error_func"
  echo "$error_msg" > "$ERROR_LOG_FILE"

  # First, commit any uncommitted work to avoid losing it
  commit_all_changes "Auto-save before error recovery (iter $ITER)" || true
  push_all_changes || true

  # Increment attempt counter
  AUTO_FIX_ATTEMPT=$((AUTO_FIX_ATTEMPT + 1))

  if [ "$AUTO_FIX_ATTEMPT" -gt "$MAX_AUTO_FIX_ATTEMPTS" ]; then
    log "Max auto-fix attempts ($MAX_AUTO_FIX_ATTEMPTS) reached. Manual intervention required."
    log_status "Stopped - Max auto-fix attempts exceeded"
    exit 1
  fi

  # Try to resolve with Claude
  if resolve_error_with_claude; then
    log "Error resolution attempted. Restarting loop..."
    AUTO_FIX_ATTEMPT=0  # Reset on successful fix
    return 0
  fi

  # If Claude fix didn't work, try basic recovery
  log "Claude fix did not resolve issue. Attempting basic recovery..."

  # Basic recovery: try to get to a clean state
  git reset --hard HEAD 2>/dev/null || true
  git clean -fd 2>/dev/null || true
  checkout_main_branch || true

  return 0
}

# Main loop with error handling wrapper
run_main_loop() {
  while true; do
  log_progress "ITERATION $ITER" "Starting (mode detection)"
  log_status "Iteration $ITER - Starting"

  # Memory management: cleanup and check before starting builders
  run_full_cleanup

  local available_mem
  available_mem=$(get_available_memory_mb)
  local total_mem
  total_mem=$(get_total_memory_mb)
  local mem_percent=$(( available_mem * 100 / (total_mem + 1) ))
  log_progress "MEMORY" "Available: ${available_mem}MB / ${total_mem}MB (${mem_percent}% free)"

  if ! check_memory_available "$MIN_MEMORY_MB"; then
    log_progress "MEMORY" "CRITICAL: Only ${available_mem}MB available (need ${MIN_MEMORY_MB}MB)"
    log "Running aggressive cleanup..."

    # Aggressive cleanup - kill all stale processes
    run_full_cleanup
    cleanup_zombie_processes

    available_mem=$(get_available_memory_mb)

    if ! check_memory_available "$MIN_MEMORY_MB"; then
      log_progress "MEMORY" "Still insufficient memory (${available_mem}MB). Will run with reduced agents."
      # Continue anyway with minimal agent count - let get_recommended_agent_count handle it
    fi
  fi

  # Check if all agents are exhausted (including Copilot free tier)
  reset_daily_quota_flags  # Check for new day to reset flags
  local current_agent
  current_agent="$(get_current_agent)"
  if [ "$current_agent" = "none" ]; then
    log_agent_status
    log_progress "WAITING" "All agent tiers exhausted. Waiting for quota reset..."
    log_status "Waiting - All quotas exhausted"

    # Wait and recheck periodically
    local wait_secs=300  # 5 minutes
    local waited=0
    while [ "$(get_current_agent)" = "none" ]; do
      log "Waiting for agent availability... (${waited}s elapsed, checking every ${wait_secs}s)"
      sleep "$wait_secs"
      waited=$((waited + wait_secs))
      reset_daily_quota_flags  # Check for new day
      copilot_free_available >/dev/null 2>&1  # Triggers cooldown check
    done

    log "Agent became available: $(get_current_agent)"
    log_agent_status
  fi

  MODE="normal"
  if (( ITER % BUG_HUNT_EVERY == 0 )); then
    MODE="bughunt"
  fi
  if (( ITER % STABILITY_EVERY == 0 )); then
    MODE="stability"
  fi
  # Check if all TODO items are complete - switch to idle mode
  if todo_all_complete; then
    MODE="idle"
    log "All TODO items complete. Switching to idle mode."
  fi
  if [ -f "$FORCED_MODE_FILE" ]; then
    MODE="$(cat "$FORCED_MODE_FILE")"
    log "Forced mode: $MODE"
  fi
  echo "$MODE" > AI_MODE.txt
  log_progress "ITERATION $ITER" "Mode: $MODE"

  refresh_skill_context

  CURRENT_HASH="$(hash_tree)"
  LAST_HASH="$(cat "$LAST_HASH_FILE" 2>/dev/null || echo "")"

  if [ "$CURRENT_HASH" = "$LAST_HASH" ]; then
    STAGNANT=$(( $(cat "$STAGNANT_COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
    echo "$STAGNANT" > "$STAGNANT_COUNT_FILE"
    log "No changes detected. Stagnant count: $STAGNANT/$MAX_STAGNANT_ITERS"
    if [ "$STAGNANT" -ge "$MAX_STAGNANT_ITERS" ]; then
      log_progress "DONE" "Converged after $ITER iterations (no changes for $STAGNANT iterations)"
      log_status "Stopped - Converged"
      echo "Converged. Exiting."
      exit 0
    fi
  else
    echo 0 > "$STAGNANT_COUNT_FILE"
    echo "$CURRENT_HASH" > "$LAST_HASH_FILE"
    log "Changes detected. Resetting stagnant counter."
  fi

  # Handle idle mode - skip builders, just monitor
  if [ "$MODE" = "idle" ]; then
    log_progress "IDLE" "All tasks complete. Skipping builder phase."
    log_status "Iteration $ITER - Idle (all tasks complete)"

    # In idle mode, count toward convergence faster
    STAGNANT=$(( $(cat "$STAGNANT_COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
    echo "$STAGNANT" > "$STAGNANT_COUNT_FILE"

    if [ "$STAGNANT" -ge 3 ]; then
      log_progress "DONE" "Idle mode converged after $ITER iterations"
      log_status "Stopped - Idle (all complete)"
      echo "All tasks complete. Exiting idle mode."
      exit 0
    fi

    # Sleep longer in idle mode (5 minutes)
    log "Idle mode: sleeping 300s before next check..."
    sleep 300
    ITER=$((ITER + 1))
    continue
  fi

  checkout_main_branch
  git branch -D "$WORK_BRANCH" >/dev/null 2>&1 || true
  git checkout -b "$WORK_BRANCH"

  log_status "Iteration $ITER - Builders running"
  log_progress "BUILDERS" "Starting 5 agents (Auditor, Builder A/B, Feature, Improver)"

  if [ "$PREFER_INTERACTIVE_BUILDERS" -eq 1 ] && [ -n "$TMUX_CMD" ]; then
    run_interactive_tmux "$MODE"
  else
    run_builder_prompts "$MODE"
  fi

  log_progress "BUILDERS" "Completed"

  if ! git diff --quiet; then
    git add -A
    git commit -m "Copilot builders iteration $ITER ($MODE)"
    log_progress "COMMIT" "Builder changes committed"
  else
    log_progress "COMMIT" "No builder changes to commit"
  fi

  refresh_skill_context

  git diff HEAD~1..HEAD > "$STATE_DIR/last.diff" || true
  prepare_diff_chunks "$STATE_DIR/last.diff" || true
  REVIEW_LIST_FILE="$STATE_DIR/review_chunks/chunks.lst"
  REVIEW_TOTAL=0
  if [ -f "$REVIEW_LIST_FILE" ]; then
    REVIEW_TOTAL=$(grep -c . "$REVIEW_LIST_FILE" 2>/dev/null || echo 0)
  fi

  ROLES=("autonomous reviewer" "security reviewer" "performance reviewer" "test quality reviewer")

  log_status "Iteration $ITER - Reviewers running"
  log_progress "REVIEWERS" "Starting 4 reviewers + backlog groomer"

  if [ "$REVIEW_TOTAL" -eq 0 ]; then
    for ROLE in "${ROLES[@]}"; do
      log "  Running: $ROLE"
      run_reviewer_prompt "$ROLE" "$MODE" "" 0 0
    done
  else
    local_index=1
    while IFS= read -r CHUNK_PATH && [ -n "$CHUNK_PATH" ]; do
      log "  Reviewing chunk $local_index/$REVIEW_TOTAL"
      for ROLE in "${ROLES[@]}"; do
        run_reviewer_prompt "$ROLE" "$MODE" "$CHUNK_PATH" "$local_index" "$REVIEW_TOTAL"
      done
      local_index=$((local_index + 1))
    done < "$REVIEW_LIST_FILE"
  fi

  # Run backlog groomer to keep TODO.md fresh with new tasks
  log "  Running: backlog groomer"
  run_backlog_groomer_prompt "$MODE"

  log_progress "REVIEWERS" "Completed (including backlog groomer)"
  rm -rf "$STATE_DIR/review_chunks"

  if ! git diff --quiet; then
    git add -A
    git commit -m "Copilot review iteration $ITER"
    log_progress "COMMIT" "Reviewer changes committed"
  else
    log_progress "COMMIT" "No reviewer changes to commit"
  fi

  if [ "${AI_LOOP_KEEP_ARTIFACTS:-0}" != "1" ]; then
    rm -rf "$STATE_DIR"/last.diff test-results reports || true
  fi

  build_ok=1
  test_ok=1

  log_status "Iteration $ITER - Building"
  log_progress "BUILD" "Running dotnet build"

  if ! run_build; then
    build_ok=0
    echo "Build failures" >> TODO.md
    log_progress "BUILD" "FAILED - will be auto-resolved"
    save_run_memory "$ITER" "false" "false" "" "Build failed"
  else
    log_progress "BUILD" "SUCCESS"
    log_status "Iteration $ITER - Testing"
    log_progress "TEST" "Running dotnet test"
    if run_tests; then
      log_progress "TEST" "SUCCESS"
      save_run_memory "$ITER" "true" "true" "" "Tests passed"
    else
      test_ok=0
      echo "Test failures" >> TODO.md
      log_progress "TEST" "FAILED - will be auto-resolved"
      save_run_memory "$ITER" "true" "false" "" "Tests failed"
    fi
  fi

  log_status "Iteration $ITER - Merging"
  log_progress "MERGE" "Merging $WORK_BRANCH into $MAIN_BRANCH"
  checkout_main_branch

  # Ensure clean working directory before merge
  if ! git diff --quiet || ! git diff --cached --quiet; then
    log "Cleaning uncommitted changes before merge..."
    git reset --hard HEAD
  fi

  local merge_output merge_exit
  merge_output=$(git merge --no-ff --no-edit "$WORK_BRANCH" 2>&1) || merge_exit=$?

  if [ "${merge_exit:-0}" -ne 0 ]; then
    if echo "$merge_output" | grep -q "Already up to date\|Already up-to-date"; then
      log_progress "MERGE" "Already up to date"
    elif echo "$merge_output" | grep -q "CONFLICT\|Merge conflict\|conflict"; then
      log_progress "MERGE" "Conflict detected - auto-resolving with --theirs"
      echo "WARNING: Merge conflict detected - auto-resolving with --theirs (incoming changes win)" >&2
      git checkout --theirs . 2>/dev/null || true
      git add -A
      if ! git commit -m "Auto-resolve merge conflict (--theirs)"; then
        log_progress "MERGE" "FAILED - could not commit conflict resolution"
        echo "- [ ] Git merge conflict between $WORK_BRANCH and $MAIN_BRANCH needs manual resolution" >> TODO.md
        echo "stability" > "$FORCED_MODE_FILE"
        git merge --abort 2>/dev/null || true
      fi
    else
      # Other merge error - abort and retry with strategy
      log_progress "MERGE" "Merge failed - retrying with ort strategy"
      git merge --abort 2>/dev/null || true
      if ! git merge --no-ff --no-edit -X theirs "$WORK_BRANCH" 2>/dev/null; then
        log_progress "MERGE" "FAILED - could not merge branches"
        echo "- [ ] Git merge failed: $WORK_BRANCH into $MAIN_BRANCH - needs manual intervention" >> TODO.md
        echo "stability" > "$FORCED_MODE_FILE"
        git merge --abort 2>/dev/null || true
      fi
    fi
  else
    log_progress "MERGE" "SUCCESS"
  fi

  if [ "$GIT_PUSH_ON_FAILURE" -eq 1 ] || { [ "$build_ok" -eq 1 ] && [ "$test_ok" -eq 1 ]; }; then
    log_status "Iteration $ITER - Pushing"
    log_progress "PUSH" "Pushing to $GIT_PUSH_REMOTE/$MAIN_BRANCH"
    if push_main_branch; then
      log_progress "PUSH" "SUCCESS"
    else
      log_progress "PUSH" "FAILED"
    fi
  else
    log_progress "PUSH" "Skipped (build_ok=$build_ok test_ok=$test_ok)"
  fi

  log_progress "ITERATION $ITER" "Completed (build=$build_ok test=$test_ok)"

  # Update git memory and compact memory at end of each iteration
  update_git_memory
  # Compact every 3 iterations to prevent unbounded growth
  if [ $((ITER % 3)) -eq 0 ]; then
    log "Compacting memory (iteration $ITER)..."
    compact_memory
  fi

  # Safety commit/push - ensure all changes are saved before next iteration
  log "Safety commit/push before next iteration..."
  if commit_all_changes "Auto-save: End of iteration $ITER"; then
    push_all_changes || log "WARNING: Safety push failed, will retry next iteration"
  fi

  log_status "Idle - waiting for next iteration"

  # Reset auto-fix counter on successful iteration
  AUTO_FIX_ATTEMPT=0

  # Clean up zombie processes and restart script for clean memory slate
  cleanup_zombie_processes
  tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

  ITER=$((ITER + 1))

  # Persist iteration counter to file for restart
  echo "$ITER" > "$STATE_DIR/iteration_count.txt"

  log_progress "RESTART" "Restarting script for clean memory (next iteration: $ITER)"

  # exec replaces current process - releases all memory
  exec "$SCRIPT_DIR/$(basename "$0")" "$@"
  done
}

# ============================================================
# OUTER ERROR-CATCHING LOOP
# Wraps main loop in try-catch, auto-resolves errors, restarts
# ============================================================

# Initial memory setup and diagnostics
log "=============================================="
log "MEMORY MANAGEMENT INITIALIZATION"
log "=============================================="

# Try to set up swap if not present (safety buffer)
setup_swap_if_needed

# Initial memory status
initial_mem=$(get_available_memory_mb)
total_mem=$(get_total_memory_mb)
log "Initial memory: ${initial_mem}MB available / ${total_mem}MB total"
log "Memory thresholds: MIN=${MIN_MEMORY_MB}MB, LOW=${LOW_MEMORY_MB}MB"
log "Agent counts: FULL=$MEMORY_AGENT_FULL, REDUCED=$MEMORY_AGENT_REDUCED"

# Initial cleanup
log "Running initial cleanup..."
run_full_cleanup

log "Starting error-resilient outer loop..."
log "Auto-fix attempts allowed: $MAX_AUTO_FIX_ATTEMPTS"

while true; do
  # Reset error trap for each iteration
  set +e  # Don't exit on error

  # Capture errors with trap
  error_occurred=0
  error_message=""
  error_lineno=""

  trap 'error_occurred=1; error_message="$BASH_COMMAND failed with exit code $?"; error_lineno="$LINENO"' ERR

  # Run the main loop (will exit on unhandled error)
  run_main_loop
  main_loop_exit=$?

  trap - ERR  # Clear trap

  if [ "$error_occurred" -eq 1 ] || [ "$main_loop_exit" -ne 0 ]; then
    log_progress "ERROR" "Main loop exited unexpectedly (exit=$main_loop_exit, error=$error_occurred)"

    # Handle the error
    handle_loop_error "$error_message" "$error_lineno" "main_loop"

    # Brief pause before restart
    log "Pausing 10s before restart..."
    sleep 10

    # Ensure we're on a clean branch before restart
    checkout_main_branch || true

    log_progress "RESTART" "Restarting main loop after error recovery"
    continue
  fi

  # If main loop exits cleanly (convergence), break outer loop
  log "Main loop exited cleanly. Stopping."
  break
done

log "AI autonomous loop terminated."
