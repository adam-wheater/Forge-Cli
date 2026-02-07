param (
    [string]$RepoUrl,
    [string]$RepoName,
    [string]$Branch = "ai/unit-tests",
    [int]$MaxLoops = 8,
    [switch]$DebugMode
)

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

git clone $RepoUrl
if ($LASTEXITCODE -ne 0) { throw "git clone failed for $RepoUrl (exit code $LASTEXITCODE)" }

Set-Location $RepoName

git checkout -b $Branch
if ($LASTEXITCODE -ne 0) { throw "git checkout -b $Branch failed (exit code $LASTEXITCODE)" }

. "$PSScriptRoot/lib/Orchestrator.ps1"
. "$PSScriptRoot/lib/RepoMemory.ps1"

# Initialize memory on first run (scan repo structure)
$repoMap = Initialize-RepoMemory (Get-Location)
Write-DebugLog "repo-memory-init" ($repoMap | ConvertTo-Json -Depth 5)

$builderPrompt  = Get-Content "$PSScriptRoot/agents/builder.system.txt" -Raw
$reviewerPrompt = Get-Content "$PSScriptRoot/agents/reviewer.system.txt" -Raw
$judgePrompt    = Get-Content "$PSScriptRoot/agents/judge.system.txt" -Raw
$toolsBase      = Get-Content "$PSScriptRoot/agents/tools.system.txt" -Raw

for ($i = 1; $i -le $MaxLoops; $i++) {
    Write-Host "=== ITERATION $i ==="

    # C110: Reset working tree to prevent failed patches from accumulating
    git checkout -- .
    if ($LASTEXITCODE -ne 0) {
        Write-DebugLog "git-reset-failed" "git checkout -- . failed (exit code $LASTEXITCODE)"
    }

    # C114: Clean up stale patch files between iterations
    Remove-Item ai.patch -ErrorAction SilentlyContinue

    $iterationStart = Get-TotalTokens

    # Load compressed memory summary and inject into context
    $memorySummary = Get-MemorySummary
    $context = $toolsBase + "`n" + $memorySummary

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

    $patches = @()
    foreach ($h in $hypotheses) {
        $patches += Run-Agent "builder" $env:BUILDER_DEPLOYMENT $builderPrompt "$context`nFOCUS:$h"
    }

    Write-DebugLog "candidate-patches" ($patches -join "`n---`n")

    $judgeInput = "Select best patch:`n" + ($patches -join "`n---`n")
    $chosen = Invoke-AzureAgent $env:JUDGE_DEPLOYMENT $judgePrompt $judgeInput
    Write-DebugLog "judge-choice" $chosen

    # C109: Wire up reviewer agent after judge, before git apply
    $reviewerDeployment = if ($env:REVIEWER_DEPLOYMENT) { $env:REVIEWER_DEPLOYMENT } else { $env:JUDGE_DEPLOYMENT }
    $reviewed = Run-Agent "reviewer" $reviewerDeployment $reviewerPrompt "Review this patch:`n$chosen"
    Write-DebugLog "reviewer-output" $reviewed
    if ($reviewed -and $reviewed -ne "NO_CHANGES") {
        $chosen = $reviewed
    }

    # C111: Validate judge output is a valid unified diff before applying
    if ($chosen -notmatch '^(diff --git|---)') {
        Write-DebugLog "invalid-patch" "Chosen patch is not a valid unified diff"
        Save-RunState -Iteration $i -BuildOk $false -TestOk $false `
            -Attempts @($hypotheses) -DiffSummary "Invalid patch format"
        Enforce-Budgets $iterationStart
        continue
    }

    $chosen | Out-File ai.patch -Encoding utf8
    git apply ai.patch
    if ($LASTEXITCODE -ne 0) {
        Write-DebugLog "apply-failed" "git apply failed (exit code $LASTEXITCODE)"
        Save-RunState -Iteration $i -BuildOk $false -TestOk $false `
            -Attempts @($hypotheses) -DiffSummary "git apply failed"
        Enforce-Budgets $iterationStart
        continue
    }
    Write-DebugLog "applied-diff" (git diff)

    $buildOk = $true
    $testOk = $true

    # D15: Support PowerShell project build/test
    if ($repoMap.projectType -eq "powershell") {
        # PowerShell projects have no build step
        Write-DebugLog "build-skip" "PowerShell project — no build step required"
    } else {
        dotnet build
        if ($LASTEXITCODE -ne 0) {
            $buildOk = $false
            # Save run state with build failure
            Save-RunState -Iteration $i -BuildOk $false -TestOk $false `
                -Attempts @($hypotheses) `
                -DiffSummary "Build failed after applying patch"
            Update-CodeIntel (Get-Location)
            Enforce-Budgets $iterationStart
            continue
        }
    }

    if ($repoMap.projectType -eq "powershell") {
        $testOutput = Invoke-Pester -PassThru 2>&1 | Out-String
    } else {
        $testOutput = dotnet test 2>&1 | Out-String
    }
    Write-DebugLog "test-output" $testOutput

    if ($LASTEXITCODE -ne 0) {
        $testOk = $false

        # Extract failing test names for heuristics
        $failedTests = @()
        $failedFiles = @()
        $testOutput -split "`n" | ForEach-Object {
            if ($_ -match 'Failed\s+(\S+)') { $failedTests += $Matches[1] }
            if ($_ -match '(?:at|in)\s+(\S+\.cs):') { $failedFiles += $Matches[1] }
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
        continue
    }

    # Success — save clean run state
    Save-RunState -Iteration $i -BuildOk $true -TestOk $true `
        -DiffSummary "Tests passed on iteration $i"
    Update-CodeIntel (Get-Location)
    Enforce-Budgets $iterationStart

    git commit -am "AI: generate and fix unit tests"
    if ($LASTEXITCODE -ne 0) {
        Write-DebugLog "commit-failed" "git commit failed (exit code $LASTEXITCODE)"
        throw "git commit failed after successful tests (exit code $LASTEXITCODE)"
    }
    Write-Host "✅ SUCCESS"
    exit 0
}

throw "❌ Failed after $MaxLoops iterations"
