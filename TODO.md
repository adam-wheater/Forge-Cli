# TODO

## C stream: Bug fixes
- [x] **C106 — Add error handling for missing or failed git log/blame calls in RepoMemory.ps1** — lib/RepoMemory.ps1 L162, L393, L405
- [x] **C107 — Add error handling for Write-MemoryFile failures in RepoMemory.ps1** — lib/RepoMemory.ps1 L170, L380
- [x] **C108 — Add error handling for file not found in Get-BlameForFile in RepoMemory.ps1** — lib/RepoMemory.ps1 L395, L405
- [x] **C92 — Add logging to all empty catch blocks in RepoMemory.ps1** — lib/RepoMemory.ps1 L166, L374, L407
- [x] **C93 — Add error handling for missing file in RepoMemory.ps1** — lib/RepoMemory.ps1 L166
- [x] **C94 — Add logging to empty catch block in RepoMemory.ps1** — lib/RepoMemory.ps1 L374
- [x] **C95 — Add logging to empty catch block in RepoMemory.ps1** — lib/RepoMemory.ps1 L407
- [x] **C101 — Add warning log to all catch blocks in RepoMemory.ps1** — lib/RepoMemory.ps1 L166, L374, L407, L411
- [x] **C59 — Ensure all error budget checks in TokenBudget.ps1 throw with clear messages** — lib/TokenBudget.ps1 L30
- [x] **C60 — Add forbidden tool error handling in Orchestrator.ps1** — lib/Orchestrator.ps1 L34
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
- [x] **C103 — Add error handling for git log and blame calls in RepoMemory.ps1** — lib/RepoMemory.ps1 L162, L393, L405
- [x] **C104 — Add error handling for Write-MemoryFile in RepoMemory.ps1** — lib/RepoMemory.ps1 L170, L380
- [x] **C105 — Add error handling for file not found in Get-BlameForFile in RepoMemory.ps1** — lib/RepoMemory.ps1 L395, L405

## D stream: New features
- [x] **D10 — Add retry mechanism with exponential backoff for Azure OpenAI API calls** — lib/AzureAgent.ps1
- [x] **D11 — Add configurable timeout for agent execution in Orchestrator.ps1** — lib/Orchestrator.ps1 (MAX_AGENT_ITERATIONS=20)
- [x] **D12 — Add [Parameter(Mandatory)] validation attributes to all lib/ functions** — lib/*.ps1
- [x] **D13 — Add startup validation for required environment variables (AZURE_OPENAI_ENDPOINT, API_KEY, API_VERSION)** — run.ps1
- [x] **D14 — Add structured error response type for agent failures** — lib/Orchestrator.ps1

## C stream: Bug fixes (new)
- [ ] **C109 — Wire up reviewer agent in the main loop** — run.ps1 L37. Reviewer is loaded but never called; the safety gate is entirely missing. Add a reviewer pass after the judge selects a patch, before applying it.
- [ ] **C110 — Add git reset between loop iterations** — run.ps1 L68, L93. Failed patches and test runs leave dirty working tree state. Add `git checkout -- .` before each retry so iterations start clean.
- [ ] **C111 — Validate judge output is a valid unified diff before applying** — run.ps1 L66. If the judge returns commentary or malformed output, `git apply` fails silently. Add patch format validation.
- [ ] **C112 — Move Enforce-Budgets to run every iteration, not just on failure** — run.ps1 L122. Currently only called when tests fail. Successful iterations with expensive API calls can blow past cost limits.
- [ ] **C113 — Default RepoName from RepoUrl when not provided** — run.ps1 L3. `$RepoName` has no default; if omitted, `Set-Location $RepoName` fails with empty string. Derive from URL if not provided.
- [ ] **C114 — Clean up ai.patch file between iterations** — run.ps1 L66. Stale patch file persists if a subsequent iteration's judge returns NO_CHANGES.

## D stream: New features (new)
- [ ] **D15 — Support PowerShell project build/test in run.ps1** — run.ps1 L79, L90. Currently hardcodes `dotnet build` and `dotnet test`. RepoMemory detects project type but run.ps1 ignores it. Add conditional logic to run Pester for PowerShell repos.
- [ ] **D16 — Use Get-SuggestedFix to inform builder hypotheses** — run.ps1 L49. The 3 hypotheses are static strings. Use heuristics/known-fix data from RepoMemory to generate smarter, context-aware hypotheses.
- [ ] **D17 — Add PowerShell file scoring in Score-File** — lib/RepoTools.ps1 L7. Score-File only scores .cs files. Add scoring for .ps1, .Tests.ps1, and PowerShell module patterns.

## E stream: Test coverage
- [x] **E27 — Add/verify Pester tests for TokenBudget.ps1 error budget enforcement** — lib/TokenBudget.ps1 L30
- [x] **E28 — Add/verify Pester tests for forbidden tool error in Orchestrator.ps1** — lib/Orchestrator.ps1 L34
- [x] **E30 — Add Pester tests for AzureAgent.ps1 error handling (HTTP failures, null responses)** — lib/AzureAgent.ps1
- [x] **E31 — Add Pester tests for Orchestrator.ps1 JSON parsing robustness** — lib/Orchestrator.ps1
- [x] **E32 — Add Pester tests for infinite loop prevention in Orchestrator.ps1** — lib/Orchestrator.ps1
- [x] **E33 — Add Pester tests for parameter validation across all lib modules** — lib/*.ps1
