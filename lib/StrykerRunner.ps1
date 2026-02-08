# StrykerRunner.ps1 — Stryker.NET mutation testing integration (I03)
# Runs dotnet-stryker with timeout, parses mutation-report.json,
# extracts surviving mutants, and generates test hypotheses to kill them.

function Invoke-StrykerAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$Filter = ""
    )

    if (-not (Test-Path $RepoRoot -PathType Container)) {
        Write-Warning "Invoke-StrykerAnalysis: RepoRoot '$RepoRoot' does not exist."
        return $null
    }

    # Build the dotnet-stryker command arguments
    $strykerArgs = @()
    if ($Filter) {
        $strykerArgs += "--mutate"
        $strykerArgs += $Filter
    }
    $strykerArgs += "--reporter"
    $strykerArgs += "json"

    # Run dotnet-stryker via Start-Job with timeout
    $job = Start-Job -ScriptBlock {
        param($root, $args)
        Set-Location $root
        & dotnet-stryker @args 2>&1
    } -ArgumentList $RepoRoot, $strykerArgs

    $timeoutSeconds = 300
    $completed = $job | Wait-Job -Timeout $timeoutSeconds
    if (-not $completed -or $job.State -ne 'Completed') {
        Write-Warning "Invoke-StrykerAnalysis: dotnet-stryker timed out after ${timeoutSeconds}s."
        $job | Stop-Job -ErrorAction SilentlyContinue
        $job | Remove-Job -Force -ErrorAction SilentlyContinue
        return $null
    }

    $output = Receive-Job $job
    $job | Remove-Job -Force -ErrorAction SilentlyContinue

    # Find the mutation report JSON file
    $reportPaths = @(
        (Join-Path $RepoRoot "StrykerOutput"),
        (Join-Path $RepoRoot "stryker-output")
    )

    $reportFile = $null
    foreach ($basePath in $reportPaths) {
        if (Test-Path $basePath) {
            $found = Get-ChildItem $basePath -Filter "mutation-report.json" -Recurse -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($found) {
                $reportFile = $found.FullName
                break
            }
        }
    }

    if (-not $reportFile) {
        Write-Warning "Invoke-StrykerAnalysis: No mutation-report.json found in StrykerOutput."
        return $null
    }

    try {
        $reportContent = Get-Content $reportFile -Raw -ErrorAction Stop
        $report = $reportContent | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Warning "Invoke-StrykerAnalysis: Failed to parse mutation report: $_"
        return $null
    }

    return $report
}

function Get-SurvivingMutants {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$StrykerReport
    )

    $mutants = @()

    if (-not $StrykerReport) {
        Write-Warning "Get-SurvivingMutants: StrykerReport is null."
        return $mutants
    }

    # Stryker.NET JSON report structure:
    # { files: { "path/to/file.cs": { mutants: [ { id, mutatorName, status, location, replacement, description } ] } } }
    $files = $null
    if ($StrykerReport.PSObject.Properties['files']) {
        $files = $StrykerReport.files
    }

    if (-not $files) {
        Write-Warning "Get-SurvivingMutants: No files found in Stryker report."
        return $mutants
    }

    foreach ($prop in $files.PSObject.Properties) {
        $filePath = $prop.Name
        $fileData = $prop.Value

        $fileMutants = $null
        if ($fileData.PSObject.Properties['mutants']) {
            $fileMutants = $fileData.mutants
        }

        if (-not $fileMutants) { continue }

        foreach ($mutant in $fileMutants) {
            # Only include surviving mutants (not killed, not timeout, not no-coverage)
            if ($mutant.status -ne 'Survived') { continue }

            $location = $null
            if ($mutant.PSObject.Properties['location']) {
                $location = $mutant.location
            }

            $startLine = 0
            $endLine = 0
            if ($location) {
                if ($location.PSObject.Properties['start']) {
                    $startLine = $location.start.line
                }
                if ($location.PSObject.Properties['end']) {
                    $endLine = $location.end.line
                }
            }

            # Map mutation type to human-readable description
            $mutationType = $mutant.mutatorName
            $description = switch -Wildcard ($mutationType) {
                "ConditionalExpression*"  { "negated conditional expression" }
                "EqualityOperator*"       { "changed equality operator" }
                "BooleanLiteral*"         { "flipped boolean literal" }
                "ArithmeticOperator*"     { "changed arithmetic operator" }
                "StringLiteral*"          { "changed string literal" }
                "NullCoalescing*"         { "removed null coalescing" }
                "CheckedStatement*"       { "removed checked statement" }
                "LinqMethod*"             { "changed LINQ method" }
                "MethodCall*"             { "removed method call" }
                "UnaryOperator*"          { "removed unary operator" }
                "UpdateOperator*"         { "changed update operator" }
                "LogicalOperator*"        { "changed logical operator" }
                "AssignmentStatement*"    { "changed assignment" }
                "Block*"                  { "removed code block" }
                default                    { "mutated code ($mutationType)" }
            }

            $replacement = ""
            if ($mutant.PSObject.Properties['replacement']) {
                $replacement = $mutant.replacement
            }
            if ($mutant.PSObject.Properties['description']) {
                $description = $mutant.description
            }

            $mutants += @{
                File         = $filePath
                Line         = $startLine
                EndLine      = $endLine
                MutatorName  = $mutationType
                Description  = $description
                Replacement  = $replacement
                Status       = $mutant.status
                Id           = $mutant.id
            }
        }
    }

    return $mutants
}

function Get-MutantKillHypotheses {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][array]$Mutants,
        [int]$MaxHypotheses = 5
    )

    if (-not $Mutants -or $Mutants.Count -eq 0) {
        return @()
    }

    $hypotheses = @()

    # Group mutants by file for batched hypotheses
    $byFile = @{}
    foreach ($m in $Mutants) {
        $file = $m.File
        if (-not $byFile.ContainsKey($file)) {
            $byFile[$file] = @()
        }
        $byFile[$file] += $m
    }

    foreach ($file in $byFile.Keys) {
        $fileMutants = $byFile[$file]

        # Group by mutation type within each file
        $byType = @{}
        foreach ($m in $fileMutants) {
            $type = $m.MutatorName
            if (-not $byType.ContainsKey($type)) {
                $byType[$type] = @()
            }
            $byType[$type] += $m
        }

        foreach ($type in $byType.Keys) {
            $typeMutants = $byType[$type]
            $lines = @($typeMutants | ForEach-Object { $_.Line }) | Sort-Object
            $description = $typeMutants[0].Description

            $hypothesis = "Add test to kill surviving mutant in $file — $description at line(s) $($lines -join ', ')."

            # Provide specific test suggestion based on mutation type
            $testSuggestion = switch -Wildcard ($type) {
                "ConditionalExpression*"  { "Assert both true and false branches of the conditional." }
                "EqualityOperator*"       { "Test boundary values around the equality check." }
                "BooleanLiteral*"         { "Verify the boolean outcome explicitly in assertions." }
                "NullCoalescing*"         { "Test with null input to verify the null-coalescing fallback." }
                "ArithmeticOperator*"     { "Verify the arithmetic result with specific expected values." }
                "MethodCall*"             { "Verify the method call occurs using mock Verify()." }
                "LinqMethod*"             { "Test with collections that produce different results for different LINQ methods." }
                default                    { "Add an assertion that distinguishes the original from the mutated code." }
            }

            $hypotheses += @{
                Hypothesis     = $hypothesis
                TestSuggestion = $testSuggestion
                File           = $file
                Lines          = $lines
                MutationType   = $type
                MutantCount    = $typeMutants.Count
            }
        }
    }

    # Sort by mutant count descending (more mutants = higher priority)
    $sorted = $hypotheses | Sort-Object { $_.MutantCount } -Descending
    $result = @($sorted | Select-Object -First $MaxHypotheses)

    return $result
}
