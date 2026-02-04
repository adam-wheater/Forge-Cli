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

$builderPrompt  = Get-Content "$PSScriptRoot/agents/builder.system.txt" -Raw
$reviewerPrompt = Get-Content "$PSScriptRoot/agents/reviewer.system.txt" -Raw
$judgePrompt    = Get-Content "$PSScriptRoot/agents/judge.system.txt" -Raw
$toolsBase      = Get-Content "$PSScriptRoot/agents/tools.system.txt" -Raw

for ($i = 1; $i -le $MaxLoops; $i++) {
    Write-Host "=== ITERATION $i ==="
    $iterationStart = Get-TotalTokens

    $context = $toolsBase

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

    dotnet build || continue

    $testOutput = dotnet test 2>&1 | Out-String
    Write-DebugLog "test-output" $testOutput

    if ($LASTEXITCODE -ne 0) {
        $context = $toolsBase
        $context += "`nTEST_FAILURES:`n$testOutput"
        $context += "`nLAST_DIFF:`n$(git diff)"
        Enforce-Budgets $iterationStart
        continue
    }

    git commit -am "AI: generate and fix unit tests"
    Write-Host "✅ SUCCESS"
    exit 0
}

throw "❌ Failed after $MaxLoops iterations"
