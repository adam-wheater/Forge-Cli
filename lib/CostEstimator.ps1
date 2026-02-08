. "$PSScriptRoot/TokenBudget.ps1"
. "$PSScriptRoot/ConfigLoader.ps1"

function Estimate-RunCost {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$RepoRoot,
        [int]$MaxLoops = 0
    )

    if (-not (Test-Path $RepoRoot)) {
        throw "Repository root not found: $RepoRoot"
    }

    # Use config for max loops if not specified
    if ($MaxLoops -le 0) {
        if ($Global:ForgeConfig -and $Global:ForgeConfig.ContainsKey("maxLoops")) {
            $MaxLoops = [int]$Global:ForgeConfig["maxLoops"]
        } else {
            $MaxLoops = 8
        }
    }

    # Count source files
    $fileCount = 0
    $totalLOC = 0
    $csFiles = @()

    try {
        $allFiles = Get-ChildItem -Path $RepoRoot -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @(".cs", ".ps1", ".json", ".xml", ".csproj", ".sln") } |
            Where-Object { $_.FullName -notmatch "(bin|obj|node_modules|\.git|\.vs|packages)" }

        $fileCount = $allFiles.Count
        $csFiles = $allFiles | Where-Object { $_.Extension -eq ".cs" }

        foreach ($file in $allFiles) {
            try {
                $lines = (Get-Content $file.FullName -ErrorAction SilentlyContinue | Measure-Object -Line).Lines
                $totalLOC += $lines
            } catch {
                # Skip files that cannot be read
            }
        }
    } catch {
        Write-Warning "Failed to scan repository files: $($_.Exception.Message)"
    }

    # Count tests
    $testCount = 0
    $failureCount = 0

    try {
        $testProjectFiles = Get-ChildItem -Path $RepoRoot -Recurse -Filter "*.csproj" -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match "(Test|Tests|\.Tests|\.Test)" }

        if ($testProjectFiles -and $testProjectFiles.Count -gt 0) {
            foreach ($proj in $testProjectFiles) {
                try {
                    $listOutput = & dotnet test $proj.FullName --list-tests --no-build 2>&1
                    $testLines = $listOutput | Where-Object { $_ -match "^\s+\S" -and $_ -notmatch "(Test run|Microsoft|Starting)" }
                    $testCount += $testLines.Count
                } catch {
                    # dotnet test --list-tests may fail if project not built; estimate from file count
                    $testFiles = Get-ChildItem -Path (Split-Path $proj.FullName -Parent) -Recurse -Filter "*Tests.cs" -ErrorAction SilentlyContinue
                    $testCount += $testFiles.Count * 5  # Estimate 5 tests per test file
                }
            }

            # Try a quick test run to count failures
            foreach ($proj in $testProjectFiles) {
                try {
                    $testOutput = & dotnet test $proj.FullName --no-build --verbosity quiet 2>&1
                    $failedMatch = $testOutput | Where-Object { $_ -match "Failed:\s+(\d+)" }
                    if ($failedMatch) {
                        foreach ($line in $failedMatch) {
                            if ($line -match "Failed:\s+(\d+)") {
                                $failureCount += [int]$Matches[1]
                            }
                        }
                    }
                } catch {
                    # Ignore test execution failures during estimation
                }
            }
        }
    } catch {
        Write-Warning "Failed to enumerate tests: $($_.Exception.Message)"
    }

    # Estimation constants (tokens)
    $avgTokensPerFileRead = 800       # Average tokens to read a source file
    $avgTokensPerAgentCall = 4000     # Average tokens per agent API call (prompt + completion)
    $avgTokensPerSearch = 1200        # Average tokens per search operation
    $agentCallsPerIteration = 3       # Builder + reviewer + judge per iteration
    $searchesPerIteration = 4         # Average file searches per iteration
    $fileReadsPerIteration = 5        # Average files opened per iteration

    # Estimate iterations needed based on failure count
    $estimatedIterations = if ($failureCount -gt 0) {
        [Math]::Min($failureCount * 2, $MaxLoops)
    } else {
        [Math]::Min(3, $MaxLoops)  # Default estimate: 3 iterations
    }

    # Calculate estimated tokens
    $fileReadTokens = $fileReadsPerIteration * $avgTokensPerFileRead * $estimatedIterations
    $agentCallTokens = $agentCallsPerIteration * $avgTokensPerAgentCall * $estimatedIterations
    $searchTokens = $searchesPerIteration * $avgTokensPerSearch * $estimatedIterations
    $estimatedTokens = $fileReadTokens + $agentCallTokens + $searchTokens

    # Calculate cost using config rates
    $promptCostPer1K = if ($Global:ForgeConfig -and $Global:ForgeConfig.ContainsKey("promptCostPer1K")) {
        [double]$Global:ForgeConfig["promptCostPer1K"]
    } else {
        $Global:PROMPT_COST_PER_1K
    }

    $completionCostPer1K = if ($Global:ForgeConfig -and $Global:ForgeConfig.ContainsKey("completionCostPer1K")) {
        [double]$Global:ForgeConfig["completionCostPer1K"]
    } else {
        $Global:COMPLETION_COST_PER_1K
    }

    # Assume roughly 60% prompt, 40% completion
    $estimatedPromptTokens = [Math]::Floor($estimatedTokens * 0.6)
    $estimatedCompletionTokens = [Math]::Floor($estimatedTokens * 0.4)

    $estimatedCostGBP = ($estimatedPromptTokens / 1000.0 * $promptCostPer1K) +
                        ($estimatedCompletionTokens / 1000.0 * $completionCostPer1K)

    # Calculate cost range (lower = 60% of estimate, upper = 180% of estimate)
    $costLower = [Math]::Round($estimatedCostGBP * 0.6, 2)
    $costUpper = [Math]::Round($estimatedCostGBP * 1.8, 2)

    # Determine confidence level
    $confidence = if ($failureCount -gt 0 -and $testCount -gt 0 -and $fileCount -gt 10) {
        "high"
    } elseif ($testCount -gt 0 -or $fileCount -gt 5) {
        "medium"
    } else {
        "low"
    }

    return @{
        EstimatedTokens        = $estimatedTokens
        EstimatedPromptTokens  = $estimatedPromptTokens
        EstimatedCompletionTokens = $estimatedCompletionTokens
        EstimatedCostGBP       = [Math]::Round($estimatedCostGBP, 2)
        CostRangeLowerGBP      = $costLower
        CostRangeUpperGBP      = $costUpper
        EstimatedIterations    = $estimatedIterations
        FileCount              = $fileCount
        CSharpFileCount        = $csFiles.Count
        TotalLOC               = $totalLOC
        TestCount              = $testCount
        FailureCount           = $failureCount
        Confidence             = $confidence
    }
}

function Format-CostEstimate {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][hashtable]$Estimate
    )

    $tokensStr = if ($Estimate.EstimatedTokens -ge 1000) {
        "$([Math]::Round($Estimate.EstimatedTokens / 1000, 0))k"
    } else {
        "$($Estimate.EstimatedTokens)"
    }

    $costRange = [string]::Format("{0:C2}", $Estimate.CostRangeLowerGBP) + "-" + [string]::Format("{0:C2}", $Estimate.CostRangeUpperGBP)

    $output = @"
Estimated cost: $costRange ($($Estimate.Confidence) confidence) for ~$tokensStr tokens across $($Estimate.EstimatedIterations) iteration(s)
  Files: $($Estimate.FileCount) ($($Estimate.CSharpFileCount) C#), LOC: $($Estimate.TotalLOC.ToString("N0"))
  Tests: $($Estimate.TestCount) found, $($Estimate.FailureCount) failing
"@

    return $output
}

function Confirm-CostThreshold {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][hashtable]$Estimate,
        [Parameter(Mandatory)][double]$ThresholdGBP
    )

    if ($Estimate.EstimatedCostGBP -le $ThresholdGBP) {
        return $true
    }

    # Check if running non-interactively
    $isInteractive = [Environment]::UserInteractive
    if (-not $isInteractive) {
        Write-Warning "Estimated cost ($([string]::Format('{0:C2}', $Estimate.EstimatedCostGBP)) GBP) exceeds threshold ($([string]::Format('{0:C2}', $ThresholdGBP)) GBP). Aborting in non-interactive mode."
        return $false
    }

    Write-Host ""
    Write-Host "WARNING: Estimated cost exceeds threshold!" -ForegroundColor Yellow
    Write-Host "  Estimated: $([string]::Format('{0:C2}', $Estimate.EstimatedCostGBP)) GBP ($($Estimate.CostRangeLowerGBP)-$($Estimate.CostRangeUpperGBP) range)" -ForegroundColor Yellow
    Write-Host "  Threshold: $([string]::Format('{0:C2}', $ThresholdGBP)) GBP" -ForegroundColor Yellow
    Write-Host ""

    try {
        $response = Read-Host "Continue anyway? (y/N)"
        if ($response -match "^[yY]") {
            return $true
        }
    } catch {
        # If Read-Host fails (non-interactive environment), reject
        Write-Warning "Unable to prompt for confirmation. Aborting."
    }

    return $false
}
