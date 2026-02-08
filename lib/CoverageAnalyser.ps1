# CoverageAnalyser.ps1 — Coverage-gap-driven test generation (I01)
# Runs dotnet test with XPlat Code Coverage, parses Cobertura XML,
# identifies uncovered branches/lines per method, and generates
# builder hypotheses targeting specific uncovered code paths.

function Get-CoverageGaps {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot
    )

    if (-not (Test-Path $RepoRoot -PathType Container)) {
        Write-Warning "Get-CoverageGaps: RepoRoot '$RepoRoot' does not exist."
        return @()
    }

    # Run dotnet test with coverage collection via Start-Job with timeout
    $coverageDir = Join-Path $RepoRoot "TestResults"

    # Clean previous results
    if (Test-Path $coverageDir) {
        Remove-Item $coverageDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    $job = Start-Job -ScriptBlock {
        param($root)
        Set-Location $root
        & dotnet test --collect:"XPlat Code Coverage" --results-directory "$root/TestResults" 2>&1
    } -ArgumentList $RepoRoot

    $timeoutSeconds = 300
    $completed = $job | Wait-Job -Timeout $timeoutSeconds
    if (-not $completed -or $job.State -ne 'Completed') {
        Write-Warning "Get-CoverageGaps: dotnet test timed out after ${timeoutSeconds}s."
        $job | Stop-Job -ErrorAction SilentlyContinue
        $job | Remove-Job -Force -ErrorAction SilentlyContinue
        return @()
    }

    $output = Receive-Job $job
    $job | Remove-Job -Force -ErrorAction SilentlyContinue

    # Find Cobertura XML files in TestResults directory
    $coberturaFiles = @()
    if (Test-Path $coverageDir) {
        $coberturaFiles = @(Get-ChildItem $coverageDir -Filter "coverage.cobertura.xml" -Recurse -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName })
    }

    if ($coberturaFiles.Count -eq 0) {
        Write-Warning "Get-CoverageGaps: No Cobertura XML coverage files found."
        return @()
    }

    $gaps = @()

    foreach ($coberturaFile in $coberturaFiles) {
        try {
            [xml]$xml = Get-Content $coberturaFile -Raw -ErrorAction Stop
        } catch {
            Write-Warning "Get-CoverageGaps: Failed to parse '$coberturaFile': $_"
            continue
        }

        # Parse packages/classes/methods from Cobertura XML
        $packages = $xml.coverage.packages.package
        if (-not $packages) { continue }

        foreach ($pkg in $packages) {
            $classes = $pkg.classes.class
            if (-not $classes) { continue }

            foreach ($cls in $classes) {
                $className = $cls.name
                $fileName = $cls.filename

                $methods = $cls.methods.method
                if (-not $methods) { continue }

                foreach ($method in $methods) {
                    $methodName = $method.name
                    $lineCoverage = [double]$method.'line-rate'
                    $branchCoverage = [double]$method.'branch-rate'

                    # Skip fully covered methods
                    if ($lineCoverage -ge 1.0 -and $branchCoverage -ge 1.0) { continue }

                    # Find uncovered lines within this method
                    $uncoveredLines = @()
                    $lines = $method.lines.line
                    if ($lines) {
                        foreach ($line in $lines) {
                            if ([int]$line.hits -eq 0) {
                                $uncoveredLines += [int]$line.number
                            }
                        }
                    }

                    # If method-level lines are empty, check class-level lines
                    if ($uncoveredLines.Count -eq 0 -and $lineCoverage -lt 1.0) {
                        $classLines = $cls.lines.line
                        if ($classLines) {
                            foreach ($line in $classLines) {
                                if ([int]$line.hits -eq 0) {
                                    $uncoveredLines += [int]$line.number
                                }
                            }
                        }
                    }

                    # Generate suggestion based on coverage data
                    $suggestion = ""
                    if ($lineCoverage -eq 0 -and $branchCoverage -eq 0) {
                        $suggestion = "Method $className.$methodName has 0% coverage — add a basic test for the happy path."
                    } elseif ($branchCoverage -lt 0.5) {
                        $suggestion = "Test the uncovered branches of $className.$methodName (lines $($uncoveredLines -join ', '))."
                    } else {
                        $suggestion = "Improve coverage of $className.$methodName — uncovered lines: $($uncoveredLines -join ', ')."
                    }

                    $gaps += @{
                        Class           = $className
                        Method          = $methodName
                        UncoveredLines  = $uncoveredLines
                        BranchCoverage  = [Math]::Round($branchCoverage * 100, 1)
                        LineCoverage    = [Math]::Round($lineCoverage * 100, 1)
                        FileName        = $fileName
                        Suggestion      = $suggestion
                    }
                }
            }
        }
    }

    return $gaps
}

function Get-TestHypothesesFromCoverage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][array]$CoverageGaps,
        [int]$MaxHypotheses = 5
    )

    if (-not $CoverageGaps -or $CoverageGaps.Count -eq 0) {
        return @()
    }

    # Priority ranking:
    # 1. Methods with 0% line coverage (completely untested)
    # 2. Methods with low branch coverage (<50%)
    # 3. Partially covered methods (>50% but <100%)

    $ranked = @()

    # Priority 1: Zero coverage methods
    $zeroCoverage = @($CoverageGaps | Where-Object { $_.LineCoverage -eq 0 })
    foreach ($gap in $zeroCoverage) {
        $ranked += @{
            Priority   = 1
            Hypothesis = "Add initial test for $($gap.Class).$($gap.Method) — currently has 0% coverage."
            Class      = $gap.Class
            Method     = $gap.Method
            FileName   = $gap.FileName
            Suggestion = $gap.Suggestion
        }
    }

    # Priority 2: Low branch coverage methods
    $lowBranch = @($CoverageGaps | Where-Object { $_.LineCoverage -gt 0 -and $_.BranchCoverage -lt 50 })
    foreach ($gap in $lowBranch) {
        $ranked += @{
            Priority   = 2
            Hypothesis = "Test uncovered branches of $($gap.Class).$($gap.Method) — branch coverage is $($gap.BranchCoverage)%."
            Class      = $gap.Class
            Method     = $gap.Method
            FileName   = $gap.FileName
            Suggestion = $gap.Suggestion
        }
    }

    # Priority 3: Partially covered methods
    $partial = @($CoverageGaps | Where-Object { $_.LineCoverage -gt 0 -and $_.BranchCoverage -ge 50 -and $_.BranchCoverage -lt 100 })
    foreach ($gap in $partial) {
        $ranked += @{
            Priority   = 3
            Hypothesis = "Improve coverage of $($gap.Class).$($gap.Method) — line coverage $($gap.LineCoverage)%, branch coverage $($gap.BranchCoverage)%."
            Class      = $gap.Class
            Method     = $gap.Method
            FileName   = $gap.FileName
            Suggestion = $gap.Suggestion
        }
    }

    # Sort by priority then return top N
    $sorted = $ranked | Sort-Object { $_.Priority }
    $result = @($sorted | Select-Object -First $MaxHypotheses)

    return $result
}
