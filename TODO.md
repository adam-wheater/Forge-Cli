# TODO

## C stream: Bug fixes
- [ ] **C106 — Add error handling for missing or failed git log/blame calls in RepoMemory.ps1** — lib/RepoMemory.ps1 L162, L393, L405
- [ ] **C107 — Add error handling for Write-MemoryFile failures in RepoMemory.ps1** — lib/RepoMemory.ps1 L170, L380
- [ ] **C108 — Add error handling for file not found in Get-BlameForFile in RepoMemory.ps1** — lib/RepoMemory.ps1 L395, L405
- [ ] **C102 — Ensure all test scripts in scripts/ and tests/ are covered by at least one E-stream test** — run.ps1 L13
- [x] **C92 — Add logging to all empty catch blocks in RepoMemory.ps1** — lib/RepoMemory.ps1 L166, L374, L407
- [x] **C93 — Add error handling for missing file in RepoMemory.ps1** — lib/RepoMemory.ps1 L166
- [x] **C94 — Add logging to empty catch block in RepoMemory.ps1** — lib/RepoMemory.ps1 L374
- [x] **C95 — Add logging to empty catch block in RepoMemory.ps1** — lib/RepoMemory.ps1 L407
- [ ] **C100 — Add error handling for subprocess calls in copilot-startup-check.sh** — scripts/copilot-startup-check.sh L39
- [x] **C101 — Add warning log to all catch blocks in RepoMemory.ps1** — lib/RepoMemory.ps1 L166, L374, L407, L411
- [x] **C58 — Add completion check for TODO.md in idle mode** — ai-autonomous-loop-macos-copilot.sh L734
- [x] **C59 — Ensure all error budget checks in TokenBudget.ps1 throw with clear messages** — lib/TokenBudget.ps1 L30
- [x] **C60 — Add forbidden tool error handling in Orchestrator.ps1** — lib/Orchestrator.ps1 L34
- [x] **C61 — Ensure exit codes are handled in copilot-smoke.sh** — scripts/copilot-smoke.sh L45 (already handled via set -euo pipefail + if blocks)
- [x] **C62 — Ensure exit codes are handled in copilot-smoke.sh** — scripts/copilot-smoke.sh L50 (already handled via set -euo pipefail + if blocks)
- [x] **C63 — Ensure exit codes are handled in copilot-startup-check.sh** — scripts/copilot-startup-check.sh L18 (already handled)
- [x] **C64 — Ensure exit codes are handled in copilot-startup-check.sh** — scripts/copilot-startup-check.sh L71 (already handled)
- [x] **C65 — Ensure exit codes are handled in test-agent-fallback.sh** — scripts/test-agent-fallback.sh L57 (test stub, not production code)
- [x] **C66 — Ensure exit codes are handled in test-agent-fallback.sh** — scripts/test-agent-fallback.sh L91 (test stub, not production code)
- [x] **C67 — Ensure exit codes are handled in test-agent-fallback.sh** — scripts/test-agent-fallback.sh L543 (already handled in main function)
- [x] **C68 — Ensure exit codes are handled in test-agent-fallback.sh** — scripts/test-agent-fallback.sh L540 (already handled in main function)
- [x] **C69 — Ensure exit codes are handled in test-agent-fallback.sh** — scripts/test-agent-fallback.sh L96 (test stub, not production code)
- [x] **C70 — Ensure exit codes are handled in test-agent-fallback.sh** — scripts/test-agent-fallback.sh L118 (test stub, not production code)
- [x] **C74 — Remove unused key variable assignments in ai-autonomous-loop-macos-copilot.sh** — ai-autonomous-loop-macos-copilot.sh L1092
- [x] **C75 — Remove unused variable 'langs' in ai-autonomous-loop-macos-copilot.sh** — ai-autonomous-loop-macos-copilot.sh L1117
- [x] **C76 — Remove unused variable 'basename_set' in ai-autonomous-loop-macos-copilot.sh** — ai-autonomous-loop-macos-copilot.sh L1125
- [x] **C78 — Remove unused variable 'DETECTED_LANGUAGES' in ai-autonomous-loop-macos-copilot.sh** — ai-autonomous-loop-macos-copilot.sh L1134
- [x] **C79 — Replace hardcoded 'api-key' header with secure Authorization Bearer token in AzureAgent.ps1** — lib/AzureAgent.ps1 L24
- [x] **C80 — Add null check for API response before accessing .choices[0] in AzureAgent.ps1** — lib/AzureAgent.ps1 L35
- [x] **C81 — Add error handling for Invoke-RestMethod failure in AzureAgent.ps1** — lib/AzureAgent.ps1 L27
- [x] **C82 — Fix infinite loop: change 'continue' to 'break' on budget/tool limits in Orchestrator.ps1** — lib/Orchestrator.ps1 L39
- [x] **C83 — Add JSON parsing validation in Orchestrator.ps1 before accessing parsed fields** — lib/Orchestrator.ps1 L35
- [x] **C84 — Add git clone error handling in run.ps1** — run.ps1 L14
- [x] **C85 — Add git checkout error handling in run.ps1** — run.ps1 L16
- [x] **C86 — Add git apply error handling in run.ps1** — run.ps1 L49
- [x] **C87 — Add git commit error handling in run.ps1** — run.ps1 L65
- [x] **C88 — Add path sanitization to prevent directory traversal in DebugLogger.ps1** — lib/DebugLogger.ps1 L17
- [x] **C89 — Add catch block logging for all try/catch in RepoMemory.ps1** — lib/RepoMemory.ps1 L100
- [x] **C90 — Add forbidden tool error handling for missing permissions in ai-autonomous-loop-macos-copilot.sh** — ai-autonomous-loop-macos-copilot.sh L120
- [ ] **C91 — Add completion check for all task streams in ai-autonomous-loop-macos-copilot.sh** — ai-autonomous-loop-macos-copilot.sh L740
- [ ] **C96 — Add completion check for README.md in idle mode** — ai-autonomous-loop-macos-copilot.sh L734
- [ ] **C99 — Add error handling for subprocess calls in copilot-startup-check.sh** — scripts/copilot-startup-check.sh L39
- [ ] **C97 — Add error handling for context resource registry lookup in ai-autonomous-loop-macos-copilot.sh** — ai-autonomous-loop-macos-copilot.sh L120
- [ ] **C103 — Add error handling for git log and blame calls in RepoMemory.ps1** — lib/RepoMemory.ps1 L162, L393, L405
- [ ] **C104 — Add error handling for Write-MemoryFile in RepoMemory.ps1** — lib/RepoMemory.ps1 L170, L380
- [ ] **C105 — Add error handling for file not found in Get-BlameForFile in RepoMemory.ps1** — lib/RepoMemory.ps1 L395, L405

## D stream: New features
- [x] **D10 — Add retry mechanism with exponential backoff for Azure OpenAI API calls** — lib/AzureAgent.ps1
- [x] **D11 — Add configurable timeout for agent execution in Orchestrator.ps1** — lib/Orchestrator.ps1 (MAX_AGENT_ITERATIONS=20)
- [x] **D12 — Add [Parameter(Mandatory)] validation attributes to all lib/ functions** — lib/*.ps1
- [x] **D13 — Add startup validation for required environment variables (AZURE_OPENAI_ENDPOINT, API_KEY, API_VERSION)** — run.ps1
- [ ] **D14 — Add structured error response type for agent failures** — lib/Orchestrator.ps1

## E stream: Test coverage
- [x] **E27 — Add/verify Pester tests for TokenBudget.ps1 error budget enforcement** — lib/TokenBudget.ps1 L30
- [x] **E28 — Add/verify Pester tests for forbidden tool error in Orchestrator.ps1** — lib/Orchestrator.ps1 L34
- [x] **E29 — Add/verify Pester tests for exit/return handling in test-agent-fallback.sh** — scripts/test-agent-fallback.sh L540 (scripts already use set -euo pipefail)
- [x] **E30 — Add Pester tests for AzureAgent.ps1 error handling (HTTP failures, null responses)** — lib/AzureAgent.ps1
- [x] **E31 — Add Pester tests for Orchestrator.ps1 JSON parsing robustness** — lib/Orchestrator.ps1
- [x] **E32 — Add Pester tests for infinite loop prevention in Orchestrator.ps1** — lib/Orchestrator.ps1
- [x] **E33 — Add Pester tests for parameter validation across all lib modules** — lib/*.ps1
- [ ] **E34 — Add/verify test coverage for all error handling in copilot-startup-check.sh subprocess logic** — scripts/copilot-startup-check.sh L39
