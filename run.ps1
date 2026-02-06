param (
    [string]$RepoUrl,
    [string]$RepoName,
    [string]$Branch = "ai/unit-tests",
    [int]$MaxLoops = 8,
    [switch]$DebugMode
)

if (-not $RepoUrl) { throw "RepoUrl is required." }

. "$PSScriptRoot/lib/DebugLogger.ps1"
Init-Debug $DebugMode

git clone $RepoUrl
Set-Location $RepoName
git checkout -b $Branch

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
    $iterationStart = Get-TotalTokens

    # Load compressed memory summary and inject into context
    $memorySummary = Get-MemorySummary
    $context = $toolsBase + "`n" + $memorySummary

    $hypotheses = @(
        "Fix failing tests",
        "Fix core services under test",
        "Fix test setup or mocks"
    )

    $patches = @()
    foreach ($h in $hypotheses) {
        $patches += Run-Agent "builder" $env:BUILDER_DEPLOYMENT $builderPrompt "$context`nFOCUS:$h"
    }

    Write-DebugLog "candidate-patches" ($patches -join "`n---`n")

    $judgeInput = "Select best patch:`n" + ($patches -join "`n---`n")
    $chosen = Invoke-AzureAgent $env:JUDGE_DEPLOYMENT $judgePrompt $judgeInput
    Write-DebugLog "judge-choice" $chosen

    $chosen | Out-File ai.patch -Encoding utf8
    git apply ai.patch
    Write-DebugLog "applied-diff" (git diff)

    $buildOk = $true
    $testOk = $true

    dotnet build
    if ($LASTEXITCODE -ne 0) {
        $buildOk = $false
        # Save run state with build failure
        Save-RunState -Iteration $i -BuildOk $false -TestOk $false `
            -Attempts @($hypotheses) `
            -DiffSummary "Build failed after applying patch"
        Update-CodeIntel (Get-Location)
        continue
    }

    $testOutput = dotnet test 2>&1 | Out-String
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

    git commit -am "AI: generate and fix unit tests"
    Write-Host "✅ SUCCESS"
    exit 0
}

throw "❌ Failed after $MaxLoops iterations"
