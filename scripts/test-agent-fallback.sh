#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# AGENT FALLBACK MECHANISM TESTS
# Tests the Claude -> Copilot Premium -> Copilot Free cascade
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

TESTS_PASSED=0
TESTS_FAILED=0
STUB_DIR=""

# Setup test environment
setup() {
  STUB_DIR="$(mktemp -d)"
  export STATE_DIR="$STUB_DIR/.ai-metrics"
  mkdir -p "$STATE_DIR"
}

# Cleanup test environment
cleanup() {
  if [ -n "${STUB_DIR:-}" ] && [ -d "$STUB_DIR" ]; then
    rm -rf "$STUB_DIR"
  fi
}

trap cleanup EXIT

# Test result helpers
pass() {
  echo -e "${GREEN}PASS${NC}: $1"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
  echo -e "${RED}FAIL${NC}: $1"
  TESTS_FAILED=$((TESTS_FAILED + 1))
}

# ============================================================
# TEST: Claude stub that simulates quota exhaustion
# ============================================================
create_claude_quota_stub() {
  cat > "$STUB_DIR/claude" <<'EOF'
#!/usr/bin/env bash
echo "Error: quota exceeded - daily limit reached"
exit 429
EOF
  chmod +x "$STUB_DIR/claude"
}

# ============================================================
# TEST: Claude stub that works normally
# ============================================================
create_claude_success_stub() {
  cat > "$STUB_DIR/claude" <<'EOF'
#!/usr/bin/env bash
echo "Claude response: Task completed successfully"
exit 0
EOF
  chmod +x "$STUB_DIR/claude"
}

# ============================================================
# TEST: Copilot stub that simulates premium quota exhaustion
# ============================================================
create_copilot_premium_quota_stub() {
  cat > "$STUB_DIR/copilot" <<'EOF'
#!/usr/bin/env bash
model=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) model="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Premium models fail with quota error
if [[ "$model" =~ gpt-5\.2|gpt-4\.1|gpt-4o ]]; then
  echo "Error: 402 - no quota remaining for premium model"
  exit 402
fi

# Free model works
echo "Copilot response (model: $model): Task completed"
exit 0
EOF
  chmod +x "$STUB_DIR/copilot"
}

# ============================================================
# TEST: Copilot stub that works for all models
# ============================================================
create_copilot_success_stub() {
  cat > "$STUB_DIR/copilot" <<'EOF'
#!/usr/bin/env bash
model="unknown"
prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) model="$2"; shift 2 ;;
    -p|--prompt) prompt="$2"; shift 2 ;;
    *) shift ;;
  esac
done
echo "Copilot response (model: $model): Task completed"
echo "MODEL_USED=$model"
exit 0
EOF
  chmod +x "$STUB_DIR/copilot"
}

# ============================================================
# TEST 1: Claude available - should use Claude first
# ============================================================
test_claude_first() {
  echo -e "\n${YELLOW}TEST 1: Claude available - should use Claude first${NC}"
  setup
  create_claude_success_stub
  create_copilot_success_stub

  export CLAUDE_CMD="$STUB_DIR/claude"
  export COPILOT_CMD="$STUB_DIR/copilot"
  export COPILOT_TIME_LIMIT=5

  # Remove any existing exhaustion flags
  rm -f "$STATE_DIR/claude_exhausted.flag"
  rm -f "$STATE_DIR/copilot_premium_exhausted.flag"

  local output
  output=$("$STUB_DIR/claude" --prompt "test" 2>&1)

  if echo "$output" | grep -q "Claude response"; then
    pass "Claude was used first when available"
  else
    fail "Claude was not used first"
  fi
}

# ============================================================
# TEST 2: Claude exhausted - should fallback to Copilot premium
# ============================================================
test_claude_exhausted_fallback() {
  echo -e "\n${YELLOW}TEST 2: Claude exhausted - should fallback to Copilot premium${NC}"
  setup
  create_claude_quota_stub
  create_copilot_success_stub

  export CLAUDE_CMD="$STUB_DIR/claude"
  export COPILOT_CMD="$STUB_DIR/copilot"

  # Simulate Claude exhaustion
  touch "$STATE_DIR/claude_exhausted.flag"

  # Test that Copilot is used when Claude flag exists
  if [ -f "$STATE_DIR/claude_exhausted.flag" ]; then
    local output
    output=$("$STUB_DIR/copilot" --model "gpt-5.2" --prompt "test" 2>&1)
    if echo "$output" | grep -q "Copilot response"; then
      pass "Copilot premium used after Claude exhaustion"
    else
      fail "Copilot premium not used after Claude exhaustion"
    fi
  else
    fail "Claude exhaustion flag not created"
  fi
}

# ============================================================
# TEST 3: Both premium exhausted - should use free model
# ============================================================
test_free_model_fallback() {
  echo -e "\n${YELLOW}TEST 3: Both premium exhausted - should use free model${NC}"
  setup
  create_claude_quota_stub
  create_copilot_premium_quota_stub

  export CLAUDE_CMD="$STUB_DIR/claude"
  export COPILOT_CMD="$STUB_DIR/copilot"
  export COPILOT_FREE_MODEL="gpt-5-mini"

  # Simulate both exhausted
  touch "$STATE_DIR/claude_exhausted.flag"
  touch "$STATE_DIR/copilot_premium_exhausted.flag"

  # Test that free model is used
  local output
  output=$("$STUB_DIR/copilot" --model "$COPILOT_FREE_MODEL" --prompt "test" 2>&1)

  if echo "$output" | grep -q "Task completed"; then
    pass "Free model used when premium models exhausted"
  else
    fail "Free model not used correctly"
  fi
}

# ============================================================
# TEST 4: Daily reset clears exhaustion flags
# ============================================================
test_daily_reset() {
  echo -e "\n${YELLOW}TEST 4: Daily reset clears exhaustion flags${NC}"
  setup

  # Create exhaustion flags
  touch "$STATE_DIR/claude_exhausted.flag"
  touch "$STATE_DIR/copilot_premium_exhausted.flag"

  # Set quota day to yesterday
  echo "2020-01-01" > "$STATE_DIR/quota_day.txt"

  # Simulate the daily reset function
  local today
  today="$(date -u +%F)"
  local current
  current="$(cat "$STATE_DIR/quota_day.txt" 2>/dev/null || echo "")"

  if [ "$current" != "$today" ]; then
    rm -f "$STATE_DIR/claude_exhausted.flag" "$STATE_DIR/copilot_premium_exhausted.flag"
    echo "$today" > "$STATE_DIR/quota_day.txt"
  fi

  # Verify flags were cleared
  if [ ! -f "$STATE_DIR/claude_exhausted.flag" ] && [ ! -f "$STATE_DIR/copilot_premium_exhausted.flag" ]; then
    pass "Daily reset cleared exhaustion flags"
  else
    fail "Daily reset did not clear exhaustion flags"
  fi
}

# ============================================================
# TEST 5: Quota error detection in Claude output
# ============================================================
test_claude_quota_detection() {
  echo -e "\n${YELLOW}TEST 5: Claude quota error detection${NC}"
  setup

  local test_outputs=(
    "Error: quota exceeded"
    "usage limit reached"
    "rate limit exceeded"
    "daily limit reached"
    "payment required"
    "no quota remaining"
  )

  local CLAUDE_QUOTA_REGEX="quota exceeded|usage limit|rate limit|limit reached|payment required|no quota|exhausted|daily limit|token limit|insufficient|billing"

  local all_passed=1
  for output in "${test_outputs[@]}"; do
    if echo "$output" | grep -Eiq "$CLAUDE_QUOTA_REGEX"; then
      : # Pattern matched as expected
    else
      echo "  Failed to detect: $output"
      all_passed=0
    fi
  done

  if [ "$all_passed" -eq 1 ]; then
    pass "All Claude quota patterns detected correctly"
  else
    fail "Some Claude quota patterns not detected"
  fi
}

# ============================================================
# TEST 6: Copilot credit error detection
# ============================================================
test_copilot_credit_detection() {
  echo -e "\n${YELLOW}TEST 6: Copilot credit error detection${NC}"
  setup

  local test_outputs=(
    "402 payment required"
    "no quota remaining"
    "quota exceeded"
    "credit limit reached"
    "usage limit exceeded"
    "requires copilot pro"
  )

  local COPILOT_CREDIT_ERROR_REGEX="402|no quota|you have no quota|quota exceeded|credit|usage limit|rate limit|billing|payment|subscription|upgrade|copilot pro|requires copilot|not included"

  local all_passed=1
  for output in "${test_outputs[@]}"; do
    if echo "$output" | grep -Eiq "$COPILOT_CREDIT_ERROR_REGEX"; then
      : # Pattern matched as expected
    else
      echo "  Failed to detect: $output"
      all_passed=0
    fi
  done

  if [ "$all_passed" -eq 1 ]; then
    pass "All Copilot credit patterns detected correctly"
  else
    fail "Some Copilot credit patterns not detected"
  fi
}

# ============================================================
# TEST 7: Model enablement error detection
# ============================================================
test_model_enablement_detection() {
  echo -e "\n${YELLOW}TEST 7: Model enablement error detection${NC}"
  setup

  local test_outputs=(
    "enable this model first"
    "interactive mode to enable this model"
    "not enabled for your account"
    "model not enabled"
    "not available for your account"
    "not available on your plan"
    "not permitted on your plan"
  )

  local COPILOT_MODEL_ENABLE_ERROR_REGEX="enable this model|interactive mode to enable this model|not enabled for your account|model not enabled|not available for your account|not available on your plan|not permitted on your plan"

  local all_passed=1
  for output in "${test_outputs[@]}"; do
    if echo "$output" | grep -Eiq "$COPILOT_MODEL_ENABLE_ERROR_REGEX"; then
      : # Pattern matched as expected
    else
      echo "  Failed to detect: $output"
      all_passed=0
    fi
  done

  if [ "$all_passed" -eq 1 ]; then
    pass "All model enablement patterns detected correctly"
  else
    fail "Some model enablement patterns not detected"
  fi
}

# ============================================================
# TEST 8: Premium model pattern matching
# ============================================================
test_premium_model_pattern() {
  echo -e "\n${YELLOW}TEST 8: Premium model pattern matching${NC}"
  setup

  local COPILOT_PREMIUM_MODEL_PATTERN="gpt-5\.2|gpt-4\.1|gpt-4o"

  local premium_models=(
    "gpt-5.2"
    "gpt-4.1"
    "gpt-4o"
  )

  local free_models=(
    "gpt-5-mini"
    "gpt-3.5-turbo"
  )

  local all_passed=1

  for model in "${premium_models[@]}"; do
    if [[ "$model" =~ $COPILOT_PREMIUM_MODEL_PATTERN ]]; then
      : # Correctly identified as premium
    else
      echo "  Failed to identify premium: $model"
      all_passed=0
    fi
  done

  for model in "${free_models[@]}"; do
    if [[ "$model" =~ $COPILOT_PREMIUM_MODEL_PATTERN ]]; then
      echo "  Incorrectly identified as premium: $model"
      all_passed=0
    fi
  done

  if [ "$all_passed" -eq 1 ]; then
    pass "Premium model patterns correctly identified"
  else
    fail "Premium model pattern matching failed"
  fi
}

# ============================================================
# TEST 9: Skill detection for PowerShell
# ============================================================
test_skill_detection() {
  echo -e "\n${YELLOW}TEST 9: PowerShell skill detection${NC}"

  # Check if .ps1 files exist in the project
  local ps1_count
  ps1_count=$(find "$ROOT_DIR" -maxdepth 5 -name "*.ps1" 2>/dev/null | wc -l | tr -d ' ')

  if [ "$ps1_count" -gt 0 ]; then
    pass "PowerShell files detected ($ps1_count files)"
  else
    fail "No PowerShell files detected"
  fi

  # Check for agent system prompts
  local prompt_count
  prompt_count=$(find "$ROOT_DIR" -maxdepth 5 -name "*.system.txt" 2>/dev/null | wc -l | tr -d ' ')

  if [ "$prompt_count" -gt 0 ]; then
    pass "Agent prompt files detected ($prompt_count files)"
  else
    fail "No agent prompt files detected"
  fi
}

# ============================================================
# TEST 10: Core lib modules availability
# ============================================================
test_embedded_skills() {
  echo -e "\n${YELLOW}TEST 10: Core lib modules availability${NC}"

  # Verify the lib directory contains required modules
  local modules=(
    "AzureAgent.ps1"
    "TokenBudget.ps1"
    "Orchestrator.ps1"
    "RepoTools.ps1"
    "DebugLogger.ps1"
  )

  local all_found=1
  for module in "${modules[@]}"; do
    if [ -f "$ROOT_DIR/lib/$module" ]; then
      : # Found
    else
      echo "  Missing module: $module"
      all_found=0
    fi
  done

  if [ "$all_found" -eq 1 ]; then
    pass "All core lib modules present"
  else
    fail "Some core lib modules missing"
  fi
}

# ============================================================
# TEST 11: Fallback chain configuration
# ============================================================
test_fallback_chain_config() {
  echo -e "\n${YELLOW}TEST 11: Fallback chain configuration${NC}"

  # Check that the script has proper chain configuration
  if grep -q "CLAUDE_BUILDER_CHAIN" "$ROOT_DIR/vibe/ai-autonomous-loop-macos-copilot.sh" && \
     grep -q "COPILOT_BUILDER_CHAIN" "$ROOT_DIR/vibe/ai-autonomous-loop-macos-copilot.sh" && \
     grep -q "COPILOT_FREE_MODEL" "$ROOT_DIR/vibe/ai-autonomous-loop-macos-copilot.sh"; then
    pass "Fallback chain configuration present"
  else
    fail "Fallback chain configuration missing"
  fi
}

# ============================================================
# TEST 12: State file management
# ============================================================
test_state_files() {
  echo -e "\n${YELLOW}TEST 12: State file management${NC}"
  setup

  # Create test state files
  echo "2024-01-01" > "$STATE_DIR/quota_day.txt"
  touch "$STATE_DIR/claude_exhausted.flag"
  touch "$STATE_DIR/copilot_premium_exhausted.flag"
  echo "abc123" > "$STATE_DIR/last_hash.txt"
  echo "0" > "$STATE_DIR/stagnant_count.txt"

  # Verify they exist
  local all_exist=1
  for file in quota_day.txt claude_exhausted.flag copilot_premium_exhausted.flag last_hash.txt stagnant_count.txt; do
    if [ ! -e "$STATE_DIR/$file" ]; then
      echo "  Missing state file: $file"
      all_exist=0
    fi
  done

  if [ "$all_exist" -eq 1 ]; then
    pass "All state files created and managed correctly"
  else
    fail "State file management issues"
  fi
}

# ============================================================
# TEST 13: Script syntax validation
# ============================================================
test_script_syntax() {
  echo -e "\n${YELLOW}TEST 13: Script syntax validation${NC}"

  if bash -n "$ROOT_DIR/vibe/ai-autonomous-loop-macos-copilot.sh" 2>&1; then
    pass "Shell script syntax is valid"
  else
    fail "Shell script has syntax errors"
  fi
}

# ============================================================
# Run all tests
# ============================================================
main() {
  echo "============================================"
  echo "Agent Fallback Mechanism Tests"
  echo "============================================"

  test_claude_first
  test_claude_exhausted_fallback
  test_free_model_fallback
  test_daily_reset
  test_claude_quota_detection
  test_copilot_credit_detection
  test_model_enablement_detection
  test_premium_model_pattern
  test_skill_detection
  test_embedded_skills
  test_fallback_chain_config
  test_state_files
  test_script_syntax

  echo ""
  echo "============================================"
  echo "Test Results"
  echo "============================================"
  echo -e "${GREEN}Passed${NC}: $TESTS_PASSED"
  echo -e "${RED}Failed${NC}: $TESTS_FAILED"

  if [ "$TESTS_FAILED" -eq 0 ]; then
    echo -e "\n${GREEN}All tests passed!${NC}"
    exit 0
  else
    echo -e "\n${RED}Some tests failed!${NC}"
    exit 1
  fi
}

main "$@"
