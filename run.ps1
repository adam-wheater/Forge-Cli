param (
    [string]$RepoUrl,
    [string]$RepoName,
    [string]$Branch = "ai/unit-tests",
    [int]$MaxLoops = 8,
    [switch]$DebugMode,
    [switch]$InteractiveMode,     # K05: pause after judge, ask user approval
    [switch]$DryRun,              # K06: run pipeline without applying patches or committing
    [string]$ConfigPath = "",     # J01: path to forge.config.json
    [switch]$ResumeSession,       # F04: placeholder for session resume
    [switch]$UseWorktrees,        # J08: git worktree isolation per builder hypothesis
    [switch]$CIMode               # J09: CI mode — structured JSON output, no prompts, exit codes
)

# Load configuration (J01)
. "$PSScriptRoot/lib/ConfigLoader.ps1"
$config = Load-ForgeConfig -ConfigPath $(if ($ConfigPath) { $ConfigPath } else { "$PSScriptRoot/forge.config.json" })
$Global:ForgeConfig = $config

# Apply config defaults for parameters not explicitly provided
if (-not $PSBoundParameters.ContainsKey('MaxLoops')) {
    $MaxLoops = $config.maxLoops
}
if (-not $PSBoundParameters.ContainsKey('DebugMode') -and $config.debugMode) {
    $DebugMode = [switch]::new($true)
}

# Override token/cost budget globals from config
$Global:MAX_TOTAL_TOKENS = $config.maxTotalTokens
$Global:MAX_ITERATION_TOKENS = $config.maxIterationTokens
$Global:MAX_COST_GBP = $config.maxCostGBP

# Wire config deployment values to env vars if not already set
if ($config.builderDeployment -and -not $env:BUILDER_DEPLOYMENT) {
    $env:BUILDER_DEPLOYMENT = $config.builderDeployment
}
if ($config.judgeDeployment -and -not $env:JUDGE_DEPLOYMENT) {
    $env:JUDGE_DEPLOYMENT = $config.judgeDeployment
}
if ($config.reviewerDeployment -and -not $env:REVIEWER_DEPLOYMENT) {
    $env:REVIEWER_DEPLOYMENT = $config.reviewerDeployment
}

# J04: Multi-model strategy — per-role model configuration
$builderSearchDeployment = if ($config.builderSearchModel) { $config.builderSearchModel } else { $env:BUILDER_DEPLOYMENT }
$builderPatchDeployment = if ($config.builderPatchModel) { $config.builderPatchModel } else { $env:BUILDER_DEPLOYMENT }
$judgeModelDeployment = if ($config.judgeModel) { $config.judgeModel } else { $env:JUDGE_DEPLOYMENT }

if (-not $RepoUrl) { throw "RepoUrl is required." }

# C113: Default RepoName from RepoUrl when not provided
if (-not $RepoName) {
    $RepoName = ($RepoUrl -replace '\.git$','') -replace '.*/',''
}

$requiredEnvVars = @('AZURE_OPENAI_ENDPOINT', 'AZURE_OPENAI_API_KEY', 'AZURE_OPENAI_API_VERSION', 'BUILDER_DEPLOYMENT', 'JUDGE_DEPLOYMENT')
foreach ($var in $requiredEnvVars) {
    if (-not (Get-Item "env:$var" -ErrorAction SilentlyContinue)) {
        throw "Required environment variable $var is not set."
    }
}

. "$PSScriptRoot/lib/DebugLogger.ps1"
Init-Debug $DebugMode

# J09: CI mode suppresses interactive prompts
if ($CIMode) {
    $InteractiveMode = [switch]::new($false)
}

git clone $RepoUrl
if ($LASTEXITCODE -ne 0) { throw "git clone failed for $RepoUrl (exit code $LASTEXITCODE)" }

Set-Location $RepoName

git checkout -b $Branch
if ($LASTEXITCODE -ne 0) { throw "git checkout -b $Branch failed (exit code $LASTEXITCODE)" }

. "$PSScriptRoot/lib/Orchestrator.ps1"
. "$PSScriptRoot/lib/RepoMemory.ps1"

# Apply config values to Orchestrator rate limits
if ($config.maxSearches) { $script:MAX_SEARCHES = $config.maxSearches }
if ($config.maxOpens) { $script:MAX_OPENS = $config.maxOpens }
if ($config.maxAgentIterations) { $script:MAX_AGENT_ITERATIONS = $config.maxAgentIterations }

# J11: Enable function calling if configured
if ($config.useFunctionCalling) {
    $script:USE_FUNCTION_CALLING = $true
}

# K01: Rich CLI output helpers
function Write-ForgeStatus {
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Type = "info"  # info, success, warning, error, progress
    )
    # J09: In CI mode, only write to stderr so stdout stays clean for JSON
    if ($CIMode) {
        [Console]::Error.WriteLine("[$Type] $Message")
        return
    }
    $prefix = switch ($Type) {
        "info"     { "[*]" }
        "success"  { "[+]" }
        "warning"  { "[!]" }
        "error"    { "[-]" }
        "progress" { "[>]" }
    }
    $color = switch ($Type) {
        "info"     { "Cyan" }
        "success"  { "Green" }
        "warning"  { "Yellow" }
        "error"    { "Red" }
        "progress" { "White" }
    }
    Write-Host "$prefix $Message" -ForegroundColor $color
}

function Write-IterationHeader {
    param([int]$Iteration, [int]$MaxLoops)
    $bar = "=" * 60
    Write-Host ""
    Write-Host $bar -ForegroundColor Cyan
    Write-Host " ITERATION $Iteration / $MaxLoops" -ForegroundColor Cyan
    $tokens = Get-TotalTokens
    $cost = Get-CurrentCostGBP
    Write-Host " Tokens: $tokens / $($Global:MAX_TOTAL_TOKENS) | Cost: $([math]::Round($cost, 2)) GBP / $($Global:MAX_COST_GBP) GBP" -ForegroundColor DarkGray
    Write-Host $bar -ForegroundColor Cyan
}

# Normalize model-produced patch text: strip fences and extract unified-diff
function Normalize-Patch {
    param([string]$raw)
    if (-not $raw) { return $raw }
    # If the model returned a PSCustomObject, try to extract textual content
    if (-not ($raw -is [string])) {
        try {
            if ($raw.Content) { $raw = $raw.Content }
            else { $raw = $raw | ConvertTo-Json -Depth 6 }
        } catch { $raw = $raw.ToString() }
    }
    $text = $raw.Trim()
    # Remove triple-backtick fences and language markers
    $text = $text -replace '```[a-zA-Z0-9\-]*\r?\n', ''
    $text = $text -replace '\r?\n```$', ''
    # If the text contains a diff start, extract from there
    if ($text -match 'diff --git') {
        $idx = $text.IndexOf('diff --git')
        return $text.Substring($idx).Trim()
    }
    # If it contains standard ---/+++ headers, try to extract nearest diff
    if ($text -match '--- a/') {
        $idx = $text.IndexOf('--- a/')
        return $text.Substring($idx).Trim()
    }
    # Otherwise, return original cleaned text
    return $text
}

# Attempt automated repairs on a patch to make it applyable
function Repair-Patch {
    param(
        [string]$patchText,
        [string]$repoRoot = (Get-Location).Path
    )
    if (-not $patchText) { return $patchText }

    $workDir = $repoRoot
    $origPath = Join-Path $workDir 'tmp-logs\ai.patch.orig.txt'
    $trialPath = Join-Path $workDir 'tmp-logs\ai.patch.trial.txt'
    if (-not (Test-Path (Join-Path $workDir 'tmp-logs'))) { New-Item -ItemType Directory -Path (Join-Path $workDir 'tmp-logs') -Force | Out-Null }
    $patchText | Out-File -FilePath $origPath -Encoding utf8 -Force

    # Quick check: apply-check original
    Set-Location $workDir
    $patchText | Out-File ai.patch -Encoding utf8 -Force
    git apply --check ai.patch 2>$null
    if ($LASTEXITCODE -eq 0) { return $patchText }

    # Variant 1: strip a/ b/ prefixes in headers
    $v1 = $patchText -replace '(^---\s+)a/','$1' -replace '(^\+\+\+\s+)b/','$1'
    $v1 | Out-File ai.patch -Encoding utf8 -Force
    git apply --check ai.patch 2>$null
    if ($LASTEXITCODE -eq 0) { return $v1 }

    # Variant 2: normalize line endings (LF)
    $v2 = ($v1 -replace "\r\n","\n")
    $v2 | Out-File ai.patch -Encoding utf8 -Force
    git apply --check ai.patch 2>$null
    if ($LASTEXITCODE -eq 0) { return $v2 }

    # Variant 3: try to remove leading code fences already handled by Normalize-Patch, but try again with original
    $v3 = $patchText -replace '(^```[a-zA-Z0-9\-]*\r?\n)|(```\r?\n$)', ''
    $v3 | Out-File ai.patch -Encoding utf8 -Force
    git apply --check ai.patch 2>$null
    if ($LASTEXITCODE -eq 0) { return $v3 }

    # Last resort: attempt to apply with rejects and return the trial text (may create .rej files)
    try {
        git apply --reject --whitespace=fix ai.patch 2>$null
    } catch {}
    return $patchText
}

# Wire K modules: Initialize metrics tracking if MetricsTracker.ps1 is loaded
if (Get-Command Initialize-Metrics -ErrorAction SilentlyContinue) {
    try {
        Initialize-Metrics
        Write-DebugLog "metrics-init" "Metrics tracking initialized"
    } catch {
        Write-DebugLog "metrics-init-failed" "Failed to initialize metrics: $($_.Exception.Message)"
    }
}

# Initialize memory on first run (scan repo structure)
$repoMap = Initialize-RepoMemory (Get-Location)
Write-DebugLog "repo-memory-init" ($repoMap | ConvertTo-Json -Depth 5)

$builderPrompt  = Get-Content "$PSScriptRoot/agents/builder.system.txt" -Raw
$reviewerPrompt = Get-Content "$PSScriptRoot/agents/reviewer.system.txt" -Raw
$judgePrompt    = Get-Content "$PSScriptRoot/agents/judge.system.txt" -Raw
$toolsBase      = Get-Content "$PSScriptRoot/agents/tools.system.txt" -Raw

# J05: Incremental patching — track which tests are passing across iterations
$passingTests = @()
$testsFixedTotal = 0

# J09: CI mode tracking
$ciResult = @{
    success      = $false
    iterations   = 0
    tokensUsed   = 0
    costGBP      = 0.0
    testsFixed   = 0
    patchSummary = ""
}

# Helper: select the right Run-Agent variant based on function calling config
function Invoke-BuilderAgent {
    param(
        [Parameter(Mandatory)][string]$Deployment,
        [Parameter(Mandatory)][string]$SystemPrompt,
        [Parameter(Mandatory)][string]$Context
    )
    if ($script:USE_FUNCTION_CALLING -and (Get-Command Run-AgentWithFunctionCalling -ErrorAction SilentlyContinue)) {
        return Run-AgentWithFunctionCalling "builder" $Deployment $SystemPrompt $Context
    } else {
        return Run-Agent "builder" $Deployment $SystemPrompt $Context
    }
}

for ($i = 1; $i -le $MaxLoops; $i++) {
    Write-IterationHeader -Iteration $i -MaxLoops $MaxLoops
    $ciResult.iterations = $i

    # Wire K modules: Add metric event for iteration start
    if (Get-Command Add-MetricEvent -ErrorAction SilentlyContinue) {
        try { Add-MetricEvent -Event "iteration_start" -Data @{ iteration = $i } } catch {}
    }

    # Wire memory compaction: Update git memory at iteration start
    if (Get-Command Update-GitMemory -ErrorAction SilentlyContinue) {
        try { Update-GitMemory } catch {
            Write-DebugLog "git-memory-update-failed" $_.Exception.Message
        }
    }

    # Wire memory compaction: Compress memory every 3 iterations
    if ($i -gt 1 -and ($i % 3) -eq 1) {
        if (Get-Command Compress-Memory -ErrorAction SilentlyContinue) {
            try {
                Compress-Memory
                Write-DebugLog "memory-compacted" "Memory compacted at iteration $i"
            } catch {
                Write-DebugLog "memory-compact-failed" $_.Exception.Message
            }
        }
    }

    # J05: Incremental patching — only reset if needed
    # Instead of always resetting, check if we should keep accumulated patches
    $shouldReset = $true
    if ($passingTests.Count -gt 0) {
        # We have previously-passing tests. Check if they still pass before resetting.
        $shouldReset = $true  # Default to reset; will be overridden below if patch kept
        Write-DebugLog "incremental-check" "Tracking $($passingTests.Count) previously-passing tests"
    }

    if ($shouldReset) {
        # C110: Reset working tree to prevent failed patches from accumulating
        git checkout -- .
        if ($LASTEXITCODE -ne 0) {
            Write-DebugLog "git-reset-failed" "git checkout -- . failed (exit code $LASTEXITCODE)"
        }
    }

    # C114: Clean up stale patch files between iterations
    Remove-Item ai.patch -ErrorAction SilentlyContinue

    $iterationStart = Get-TotalTokens

    # H10: Budget-aware context injection
    $tokensUsed = Get-TotalTokens
    $tokensRemaining = $Global:MAX_TOTAL_TOKENS - $tokensUsed
    $budgetPct = [math]::Round(($tokensRemaining / $Global:MAX_TOTAL_TOKENS) * 100)
    $costUsed = Get-CurrentCostGBP
    $costRemaining = $Global:MAX_COST_GBP - $costUsed
    $budgetContext = "BUDGET_REMAINING: $tokensRemaining tokens ($budgetPct%) | Cost: $([math]::Round($costRemaining, 2)) GBP remaining"

    # Load compressed memory summary and inject into context
    $memorySummary = Get-MemorySummary
    $context = $toolsBase + "`n" + $budgetContext + "`n" + $memorySummary

    # D16: Use Get-SuggestedFix to inform builder hypotheses
    $prevState = Read-MemoryFile "run-state.json"
    $sugFailedTests = @()
    $sugFailedFiles = @()
    if ($prevState) {
        $sugFailedTests = @($prevState.lastFailures)
        $sugFailedFiles = @($prevState.recentFiles)
    }
    $suggestion = Get-SuggestedFix -FailedTests $sugFailedTests -FailedFiles $sugFailedFiles

    $hypotheses = @(
        "Fix failing tests",
        "Fix core services under test",
        "Fix test setup or mocks"
    )
    if ($suggestion) {
        $hypotheses += $suggestion
    }

    # Wire I01: Coverage-driven hypothesis generation
    if (Get-Command Get-TestHypothesesFromCoverage -ErrorAction SilentlyContinue) {
        try {
            $coverageHypotheses = Get-TestHypothesesFromCoverage
            if ($coverageHypotheses -and $coverageHypotheses.Count -gt 0) {
                $hypotheses += $coverageHypotheses
                Write-DebugLog "coverage-hypotheses" "Added $($coverageHypotheses.Count) coverage-driven hypotheses"
            }
        } catch {
            Write-DebugLog "coverage-hypotheses-failed" $_.Exception.Message
        }
    }

    Write-ForgeStatus "Running builder agents ($($hypotheses.Count) hypotheses)..." "progress"

    # Wire K modules: Add metric event for agent calls
    if (Get-Command Add-MetricEvent -ErrorAction SilentlyContinue) {
        try { Add-MetricEvent -Event "builder_start" -Data @{ hypothesisCount = $hypotheses.Count } } catch {}
    }

    # J08: Git worktree isolation
    $worktrees = @()
    $worktreeDir = $null

    if ($UseWorktrees) {
        $worktreeDir = Join-Path ([System.IO.Path]::GetTempPath()) "forge-worktrees-$i"
        if (Test-Path $worktreeDir) { Remove-Item $worktreeDir -Recurse -Force }
        New-Item -ItemType Directory -Path $worktreeDir -Force | Out-Null

        $patches = @()
        $worktreeJobs = @()

        for ($hIdx = 0; $hIdx -lt $hypotheses.Count; $hIdx++) {
            $h = $hypotheses[$hIdx]
            $wtPath = Join-Path $worktreeDir "builder-$hIdx"
            $wtBranch = "forge-wt-$i-$hIdx"

            try {
                git worktree add $wtPath -b $wtBranch HEAD 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-DebugLog "worktree-add-failed" "Failed to create worktree for hypothesis $hIdx"
                    continue
                }
                $worktrees += @{ Path = $wtPath; Branch = $wtBranch }

                # Run builder in worktree context
                $job = Start-Job -ScriptBlock {
                    param($wtPath, $scriptRoot, $builderPrompt, $contextStr, $hypothesis, $deployment, $useFc)
                    Set-Location $wtPath
                    . "$scriptRoot/lib/Orchestrator.ps1"
                    if ($useFc -and (Get-Command Run-AgentWithFunctionCalling -ErrorAction SilentlyContinue)) {
                        return Run-AgentWithFunctionCalling "builder" $deployment $builderPrompt "$contextStr`nFOCUS:$hypothesis"
                    } else {
                        return Run-Agent "builder" $deployment $builderPrompt "$contextStr`nFOCUS:$hypothesis"
                    }
                } -ArgumentList $wtPath, $PSScriptRoot, $builderPrompt, $context, $h, $builderPatchDeployment, $script:USE_FUNCTION_CALLING

                $worktreeJobs += @{ Job = $job; Index = $hIdx }
            } catch {
                Write-DebugLog "worktree-error" "Worktree setup failed for hypothesis $hIdx`: $($_.Exception.Message)"
            }
        }

        # Wait for all worktree jobs with timeout
        $jobTimeout = 300  # 5 minutes per builder
        foreach ($wj in $worktreeJobs) {
            try {
                $completed = $wj.Job | Wait-Job -Timeout $jobTimeout
                if ($completed) {
                    $result = $wj.Job | Receive-Job
                    $patches += $result
                } else {
                    $wj.Job | Stop-Job
                    Write-DebugLog "worktree-timeout" "Builder job $($wj.Index) timed out"
                    $patches += "NO_CHANGES"
                }
                $wj.Job | Remove-Job -Force
            } catch {
                Write-DebugLog "worktree-job-error" "Job $($wj.Index) error: $($_.Exception.Message)"
                $patches += "NO_CHANGES"
            }
        }
    } else {
        # J02: Parallel builder execution using Start-Job
        $patches = @()
        $parallelSupported = $true

        # Try parallel execution with Start-Job
        try {
            $builderJobs = @()
            foreach ($h in $hypotheses) {
                $job = Start-Job -ScriptBlock {
                    param($scriptRoot, $builderPrompt, $contextStr, $hypothesis, $deployment, $useFc)
                    . "$scriptRoot/lib/Orchestrator.ps1"
                    . "$scriptRoot/lib/RepoMemory.ps1"
                    if ($useFc -and (Get-Command Run-AgentWithFunctionCalling -ErrorAction SilentlyContinue)) {
                        return Run-AgentWithFunctionCalling "builder" $deployment $builderPrompt "$contextStr`nFOCUS:$hypothesis"
                    } else {
                        return Run-Agent "builder" $deployment $builderPrompt "$contextStr`nFOCUS:$hypothesis"
                    }
                } -ArgumentList $PSScriptRoot, $builderPrompt, $context, $h, $builderPatchDeployment, $script:USE_FUNCTION_CALLING

                $builderJobs += $job
            }

            # Wait for all jobs with timeout (5 minutes per builder)
            $jobTimeout = 300
            foreach ($job in $builderJobs) {
                try {
                    $completed = $job | Wait-Job -Timeout $jobTimeout
                    if ($completed) {
                        $result = $job | Receive-Job
                        $patches += $result
                    } else {
                        $job | Stop-Job
                        Write-DebugLog "builder-timeout" "Builder job timed out after ${jobTimeout}s"
                        $patches += "NO_CHANGES"
                    }
                    $job | Remove-Job -Force
                } catch {
                    Write-DebugLog "builder-job-error" "Builder job error: $($_.Exception.Message)"
                    $patches += "NO_CHANGES"
                }
            }

            Write-ForgeStatus "Parallel builder execution completed" "info"
        } catch {
            # Fallback to sequential execution
            Write-DebugLog "parallel-fallback" "Parallel execution failed, falling back to sequential: $($_.Exception.Message)"
            Write-ForgeStatus "Falling back to sequential builder execution" "warning"
            $patches = @()
            foreach ($h in $hypotheses) {
                $patches += Invoke-BuilderAgent -Deployment $builderPatchDeployment -SystemPrompt $builderPrompt -Context "$context`nFOCUS:$h"
            }
        }
    }

    # Wire K modules: Add metric event for builder completion
    if (Get-Command Add-MetricEvent -ErrorAction SilentlyContinue) {
        try { Add-MetricEvent -Event "builder_end" -Data @{ patchCount = $patches.Count } } catch {}
    }

    Write-DebugLog "candidate-patches" ($patches -join "`n---`n")
    Write-ForgeStatus "Collected $($patches.Count) candidate patches" "info"

    # If none of the builders returned a unified diff, request an explicit patch
    if (-not ($patches | Where-Object { $_ -match '^(diff --git|---)' })) {
        Write-ForgeStatus "No valid diffs found from builders; requesting explicit patch" "warning"
        $finalPatchContext = "$context`nFINAL_TASK: Using the investigation above, produce a SINGLE unified git diff that implements the fix. Return ONLY the diff starting with 'diff --git'. If there are no changes, reply exactly NO_CHANGES. Do NOT include any explanatory text."
        try {
            $extra = Invoke-BuilderAgent -Deployment $builderPatchDeployment -SystemPrompt $builderPrompt -Context $finalPatchContext
            $patches += $extra
            Write-DebugLog "explicit-patch" $extra
            # If the builder still returns tool-calls or not a diff, force a finalize call where the model must not call tools
            if ($extra -notmatch '^(diff --git|---)') {
                Write-ForgeStatus "Builders didn't emit a diff; forcing finalization call" "warning"
                $finalSystem = $builderPrompt + "`nFINALIZE_MODE: You must NOT call tools. Produce ONLY a unified git diff starting with 'diff --git' that implements the fixes. If no changes, reply exactly NO_CHANGES. Do NOT include any explanatory text."
                try {
                    $forced = Invoke-AzureAgent $builderPatchDeployment $finalSystem $finalPatchContext
                    $patches += $forced
                    Write-DebugLog "forced-explicit-patch" $forced
                    # Save forced response for inspection
                    try {
                        $logDir = Join-Path (Get-Location).Path 'tmp-logs'
                        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
                        $fp = Join-Path $logDir 'forced-patch.txt'
                        $forced | Out-File -FilePath $fp -Encoding utf8 -Force
                    } catch {}
                } catch {
                    Write-DebugLog "forced-explicit-patch-failed" $_.Exception.Message
                }
            }
        } catch {
            Write-DebugLog "explicit-patch-failed" $_.Exception.Message
        }
    }

    Write-ForgeStatus "Judge selecting best patch..." "progress"
    $judgeInput = "Select best patch:`n" + ($patches -join "`n---`n")
    $chosen = Invoke-AzureAgent $judgeModelDeployment $judgePrompt $judgeInput
    Write-DebugLog "judge-choice" $chosen
    try {
        $logDir = Join-Path (Get-Location).Path 'tmp-logs'
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $cp = Join-Path $logDir 'judge-chosen.txt'
        $chosen | Out-File -FilePath $cp -Encoding utf8 -Force
    } catch {}

    # C109: Wire up reviewer agent after judge, before git apply
    Write-ForgeStatus "Reviewer validating patch..." "progress"
    $reviewerDeployment = if ($env:REVIEWER_DEPLOYMENT) { $env:REVIEWER_DEPLOYMENT } else { $env:JUDGE_DEPLOYMENT }
    $reviewed = Run-Agent "reviewer" $reviewerDeployment $reviewerPrompt "Review this patch:`n$chosen"
    Write-DebugLog "reviewer-output" $reviewed
    if ($reviewed -and $reviewed -ne "NO_CHANGES") {
        # Check if reviewer returned a refinement request JSON
        try {
            $reviewJson = $reviewed | ConvertFrom-Json -ErrorAction Stop
            if ($reviewJson.verdict -eq "refine" -and $reviewJson.issues) {
                Write-ForgeStatus "Reviewer requested refinement ($($reviewJson.issues.Count) issues)" "warning"
                $refinementContext = "$context`nREVIEWER_FEEDBACK:`n$($reviewJson.issues -join "`n")`nFOCUS: Address reviewer issues in this patch:`n$chosen"
                $chosen = Invoke-BuilderAgent -Deployment $builderPatchDeployment -SystemPrompt $builderPrompt -Context $refinementContext
                Write-DebugLog "refinement-output" $chosen
            }
        } catch {
            # Not JSON — reviewer returned a corrected patch directly
            $chosen = $reviewed
        }
    }

    # K05: Interactive mode — pause after judge, ask user approval
    if ($InteractiveMode) {
        Write-ForgeStatus "Judge selected patch:" "info"
        Write-Host $chosen
        Write-Host ""
        $response = Read-Host "Apply this patch? (y)es / (n)o / (s)kip iteration"
        if ($response -eq 'n') {
            Write-ForgeStatus "User rejected patch. Stopping." "warning"
            exit 1
        }
        if ($response -eq 's') {
            Write-ForgeStatus "User skipped iteration." "warning"
            continue
        }
    }

    # C111: Validate judge output is a valid unified diff before applying
    if ($chosen -notmatch '^(diff --git|---)') {
        Write-ForgeStatus "Invalid patch format — not a valid unified diff" "error"
        Write-DebugLog "invalid-patch" "Chosen patch is not a valid unified diff"
        Save-RunState -Iteration $i -BuildOk $false -TestOk $false `
            -Attempts @($hypotheses) -DiffSummary "Invalid patch format"
        Enforce-Budgets $iterationStart
        # J08: Clean up worktrees
        if ($UseWorktrees -and $worktrees.Count -gt 0) {
            foreach ($wt in $worktrees) {
                try { git worktree remove $wt.Path --force 2>&1 | Out-Null } catch {}
                try { git branch -D $wt.Branch 2>&1 | Out-Null } catch {}
            }
            if ($worktreeDir -and (Test-Path $worktreeDir)) { Remove-Item $worktreeDir -Recurse -Force -ErrorAction SilentlyContinue }
        }
        continue
    }

    # K06: Dry-run mode — show patch but skip apply/build/test/commit
    if ($DryRun) {
        Write-ForgeStatus "DRY RUN — Would apply patch:" "warning"
        Write-Host $chosen
        Write-ForgeStatus "DRY RUN — Skipping build, test, and commit" "warning"
        # Still update memory and enforce budgets
        Save-RunState -Iteration $i -BuildOk $true -TestOk $true `
            -DiffSummary "Dry run — patch not applied"
        Enforce-Budgets $iterationStart
        # J08: Clean up worktrees
        if ($UseWorktrees -and $worktrees.Count -gt 0) {
            foreach ($wt in $worktrees) {
                try { git worktree remove $wt.Path --force 2>&1 | Out-Null } catch {}
                try { git branch -D $wt.Branch 2>&1 | Out-Null } catch {}
            }
            if ($worktreeDir -and (Test-Path $worktreeDir)) { Remove-Item $worktreeDir -Recurse -Force -ErrorAction SilentlyContinue }
        }
        continue
    }

    $normalized = Normalize-Patch $chosen
    # Try repairing the normalized patch to increase chance of git apply
    $repaired = Repair-Patch -patchText $normalized -repoRoot (Get-Location).Path
    $repaired | Out-File ai.patch -Encoding utf8
    Write-ForgeStatus "Applying patch..." "progress"
    git apply ai.patch
    if ($LASTEXITCODE -ne 0) {
        Write-ForgeStatus "git apply failed (exit code $LASTEXITCODE)" "error"
        Write-DebugLog "apply-failed" "git apply failed (exit code $LASTEXITCODE)"
        Save-RunState -Iteration $i -BuildOk $false -TestOk $false `
            -Attempts @($hypotheses) -DiffSummary "git apply failed"
        Enforce-Budgets $iterationStart
        # J08: Clean up worktrees
        if ($UseWorktrees -and $worktrees.Count -gt 0) {
            foreach ($wt in $worktrees) {
                try { git worktree remove $wt.Path --force 2>&1 | Out-Null } catch {}
                try { git branch -D $wt.Branch 2>&1 | Out-Null } catch {}
            }
            if ($worktreeDir -and (Test-Path $worktreeDir)) { Remove-Item $worktreeDir -Recurse -Force -ErrorAction SilentlyContinue }
        }
        continue
    }
    Write-ForgeStatus "Patch applied successfully" "success"
    Write-DebugLog "applied-diff" (git diff)

    $buildOk = $true
    $testOk = $true

    # D15: Support PowerShell project build/test
    if ($repoMap.projectType -eq "powershell") {
        # PowerShell projects have no build step
        Write-ForgeStatus "PowerShell project — no build step required" "info"
        Write-DebugLog "build-skip" "PowerShell project — no build step required"
    } else {
        Write-ForgeStatus "Building project..." "progress"
        dotnet build
        if ($LASTEXITCODE -ne 0) {
            $buildOk = $false
            Write-ForgeStatus "Build failed (exit code $LASTEXITCODE)" "error"
            # Save run state with build failure
            Save-RunState -Iteration $i -BuildOk $false -TestOk $false `
                -Attempts @($hypotheses) `
                -DiffSummary "Build failed after applying patch"
            Update-CodeIntel (Get-Location)
            Enforce-Budgets $iterationStart
            # J08: Clean up worktrees
            if ($UseWorktrees -and $worktrees.Count -gt 0) {
                foreach ($wt in $worktrees) {
                    try { git worktree remove $wt.Path --force 2>&1 | Out-Null } catch {}
                    try { git branch -D $wt.Branch 2>&1 | Out-Null } catch {}
                }
                if ($worktreeDir -and (Test-Path $worktreeDir)) { Remove-Item $worktreeDir -Recurse -Force -ErrorAction SilentlyContinue }
            }
            continue
        }
        Write-ForgeStatus "Build succeeded" "success"
    }

    Write-ForgeStatus "Running tests..." "progress"
    if ($repoMap.projectType -eq "powershell") {
        $testOutput = Invoke-Pester -PassThru 2>&1 | Out-String
    } else {
        $testOutput = dotnet test 2>&1 | Out-String
    }
    Write-DebugLog "test-output" $testOutput

    if ($LASTEXITCODE -ne 0) {
        $testOk = $false
        Write-ForgeStatus "Tests failed — will retry next iteration" "error"

        # Extract failing test names for heuristics
        $failedTests = @()
        $failedFiles = @()
        $currentPassingTests = @()
        $testOutput -split "`n" | ForEach-Object {
            if ($_ -match 'Failed\s+(\S+)') { $failedTests += $Matches[1] }
            if ($_ -match '(?:at|in)\s+(\S+\.cs):') { $failedFiles += $Matches[1] }
            if ($_ -match 'Passed\s+(\S+)') { $currentPassingTests += $Matches[1] }
        }

        # J05: Incremental patching — check if patch broke previously-passing tests
        $brokeExistingTests = $false
        if ($passingTests.Count -gt 0) {
            $brokenTests = $passingTests | Where-Object { $failedTests -contains $_ }
            if ($brokenTests.Count -gt 0) {
                $brokeExistingTests = $true
                Write-ForgeStatus "Patch broke $($brokenTests.Count) previously-passing tests — will reset" "warning"
                Write-DebugLog "incremental-broke" "Broken tests: $($brokenTests -join ', ')"
            } else {
                # Patch did not break any previously-passing tests
                # Keep accumulated patches and update passing test list
                Write-ForgeStatus "Patch did not break existing tests — keeping accumulated changes" "info"
                $passingTests = @($passingTests + $currentPassingTests | Select-Object -Unique)
                $shouldReset = $false
            }
        }

        # Update passing tests tracker with any newly passing tests
        if ($currentPassingTests.Count -gt 0) {
            $newlyPassing = $currentPassingTests | Where-Object { $passingTests -notcontains $_ }
            if ($newlyPassing.Count -gt 0) {
                $passingTests = @($passingTests + $newlyPassing | Select-Object -Unique)
                $testsFixedTotal += $newlyPassing.Count
                Write-DebugLog "incremental-progress" "Newly passing: $($newlyPassing -join ', ')"
            }
        }

        # Save run state with failure details
        Save-RunState -Iteration $i -Failures $failedTests -BuildOk $true -TestOk $false `
            -RecentFiles $failedFiles `
            -Attempts @($hypotheses) `
            -DiffSummary (git diff | Select-Object -First 50 | Out-String)

        # Update heuristics with co-failure patterns
        if ($failedFiles.Count -gt 0 -or $failedTests.Count -gt 0) {
            Update-Heuristics -FailedFiles $failedFiles -FailedTests $failedTests
        }

        # Refresh code intelligence after changes
        Update-CodeIntel (Get-Location)

        # Rebuild context with fresh memory for next iteration
        $context = $toolsBase + "`n" + (Get-MemorySummary -Focus $failedFiles)
        $context += "`nTEST_FAILURES:`n$testOutput"
        $context += "`nLAST_DIFF:`n$(git diff)"
        Enforce-Budgets $iterationStart

        # Wire K modules: Add metric event for iteration end (failure)
        if (Get-Command Add-MetricEvent -ErrorAction SilentlyContinue) {
            try { Add-MetricEvent -Event "iteration_end" -Data @{ iteration = $i; success = $false; failedCount = $failedTests.Count } } catch {}
        }

        # J08: Clean up worktrees
        if ($UseWorktrees -and $worktrees.Count -gt 0) {
            foreach ($wt in $worktrees) {
                try { git worktree remove $wt.Path --force 2>&1 | Out-Null } catch {}
                try { git branch -D $wt.Branch 2>&1 | Out-Null } catch {}
            }
            if ($worktreeDir -and (Test-Path $worktreeDir)) { Remove-Item $worktreeDir -Recurse -Force -ErrorAction SilentlyContinue }
        }
        continue
    }

    # Success — save clean run state
    Write-ForgeStatus "All tests passed!" "success"
    Save-RunState -Iteration $i -BuildOk $true -TestOk $true `
        -DiffSummary "Tests passed on iteration $i"
    Update-CodeIntel (Get-Location)
    Enforce-Budgets $iterationStart

    # Wire K modules: Add metric event for iteration end (success)
    if (Get-Command Add-MetricEvent -ErrorAction SilentlyContinue) {
        try { Add-MetricEvent -Event "iteration_end" -Data @{ iteration = $i; success = $true } } catch {}
    }

    # J08: Clean up worktrees after success
    if ($UseWorktrees -and $worktrees.Count -gt 0) {
        foreach ($wt in $worktrees) {
            try { git worktree remove $wt.Path --force 2>&1 | Out-Null } catch {}
            try { git branch -D $wt.Branch 2>&1 | Out-Null } catch {}
        }
        if ($worktreeDir -and (Test-Path $worktreeDir)) { Remove-Item $worktreeDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Write-ForgeStatus "Committing changes..." "progress"
    git commit -am "AI: generate and fix unit tests"
    if ($LASTEXITCODE -ne 0) {
        Write-ForgeStatus "git commit failed (exit code $LASTEXITCODE)" "error"
        Write-DebugLog "commit-failed" "git commit failed (exit code $LASTEXITCODE)"
        throw "git commit failed after successful tests (exit code $LASTEXITCODE)"
    }
    Write-ForgeStatus "Changes committed successfully" "success"

    # Wire K modules: Save metrics at end of successful run
    if (Get-Command Save-Metrics -ErrorAction SilentlyContinue) {
        try { Save-Metrics } catch {
            Write-DebugLog "metrics-save-failed" $_.Exception.Message
        }
    }

    # Run summary
    $totalTokens = Get-TotalTokens
    $totalCost = Get-CurrentCostGBP

    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-ForgeStatus "RUN SUMMARY" "info"
    Write-ForgeStatus "Total tokens: $totalTokens" "info"
    Write-ForgeStatus "Total cost: $([math]::Round($totalCost, 4)) GBP" "info"
    Write-ForgeStatus "Iterations: $i / $MaxLoops" "info"
    Write-ForgeStatus "Tests fixed: $testsFixedTotal" "info"
    if ($DryRun) { Write-ForgeStatus "Mode: DRY RUN (no changes applied)" "warning" }
    Write-Host ("=" * 60) -ForegroundColor Cyan

    # J09: CI mode — output structured JSON and post PR comment
    if ($CIMode) {
        $ciResult.success = $true
        $ciResult.iterations = $i
        $ciResult.tokensUsed = $totalTokens
        $ciResult.costGBP = [math]::Round($totalCost, 4)
        $ciResult.testsFixed = $testsFixedTotal
        $ciResult.patchSummary = (git diff HEAD~1 --stat | Out-String).Trim()

        # Output structured JSON to stdout
        $ciResult | ConvertTo-Json -Depth 5 -Compress

        # Post PR comment if GITHUB_TOKEN is set
        if ($env:GITHUB_TOKEN) {
            try {
                $prNumber = $null
                # Try to detect PR number from environment (GitHub Actions)
                if ($env:GITHUB_REF -match 'refs/pull/(\d+)') {
                    $prNumber = $matches[1]
                }
                if ($prNumber) {
                    $commentBody = "## Forge CLI Results`n`n"
                    $commentBody += "- **Status**: SUCCESS`n"
                    $commentBody += "- **Iterations**: $($ciResult.iterations)`n"
                    $commentBody += "- **Tokens used**: $($ciResult.tokensUsed)`n"
                    $commentBody += "- **Cost**: $($ciResult.costGBP) GBP`n"
                    $commentBody += "- **Tests fixed**: $($ciResult.testsFixed)`n"
                    $commentBody += "`n### Patch Summary`n``````n$($ciResult.patchSummary)`n```````n"

                    gh pr comment $prNumber --body $commentBody 2>&1 | Out-Null
                    Write-DebugLog "ci-pr-comment" "Posted PR comment to #$prNumber"
                }
            } catch {
                Write-DebugLog "ci-pr-comment-failed" $_.Exception.Message
            }
        }

        exit 0
    }

    Write-ForgeStatus "SUCCESS" "success"
    exit 0
}

# Wire K modules: Save metrics on run completion (failure path)
if (Get-Command Save-Metrics -ErrorAction SilentlyContinue) {
    try { Save-Metrics } catch {
        Write-DebugLog "metrics-save-failed" $_.Exception.Message
    }
}

# Run summary on failure
$totalTokens = Get-TotalTokens
$totalCost = Get-CurrentCostGBP

Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-ForgeStatus "RUN SUMMARY" "info"
Write-ForgeStatus "Total tokens: $totalTokens" "info"
Write-ForgeStatus "Total cost: $([math]::Round($totalCost, 4)) GBP" "info"
Write-ForgeStatus "Iterations: $MaxLoops / $MaxLoops" "info"
Write-ForgeStatus "Tests fixed: $testsFixedTotal" "info"
if ($DryRun) { Write-ForgeStatus "Mode: DRY RUN (no changes applied)" "warning" }
Write-Host ("=" * 60) -ForegroundColor Cyan

# J09: CI mode — output structured JSON on failure
if ($CIMode) {
    $ciResult.success = $false
    $ciResult.iterations = $MaxLoops
    $ciResult.tokensUsed = $totalTokens
    $ciResult.costGBP = [math]::Round($totalCost, 4)
    $ciResult.testsFixed = $testsFixedTotal
    $ciResult.patchSummary = "Failed after $MaxLoops iterations"

    # Output structured JSON to stdout
    $ciResult | ConvertTo-Json -Depth 5 -Compress

    # Post PR comment if GITHUB_TOKEN is set
    if ($env:GITHUB_TOKEN) {
        try {
            $prNumber = $null
            if ($env:GITHUB_REF -match 'refs/pull/(\d+)') {
                $prNumber = $matches[1]
            }
            if ($prNumber) {
                $commentBody = "## Forge CLI Results`n`n"
                $commentBody += "- **Status**: FAILED`n"
                $commentBody += "- **Iterations**: $($ciResult.iterations)`n"
                $commentBody += "- **Tokens used**: $($ciResult.tokensUsed)`n"
                $commentBody += "- **Cost**: $($ciResult.costGBP) GBP`n"
                $commentBody += "- **Tests fixed**: $($ciResult.testsFixed)`n"

                gh pr comment $prNumber --body $commentBody 2>&1 | Out-Null
                Write-DebugLog "ci-pr-comment" "Posted failure PR comment to #$prNumber"
            }
        } catch {
            Write-DebugLog "ci-pr-comment-failed" $_.Exception.Message
        }
    }

    exit 1
}

throw "Failed after $MaxLoops iterations"
