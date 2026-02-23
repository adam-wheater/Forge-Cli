. "$PSScriptRoot/RelevanceTracker.ps1"

function Score-File {
    param ([Parameter(Mandatory)][string]$Path)

    $score = 0
    # Optimisation: Use string methods for faster matching than regex
    $comparison = [System.StringComparison]::OrdinalIgnoreCase

    if ($Path.IndexOf('Test', $comparison) -ge 0) { $score += 50 }

    if ($Path.IndexOf('Service', $comparison) -ge 0 -or
        $Path.IndexOf('Controller', $comparison) -ge 0 -or
        $Path.IndexOf('Manager', $comparison) -ge 0 -or
        $Path.IndexOf('Repo', $comparison) -ge 0) {
        $score += 15
    }

    if ($Path.EndsWith('.cs', $comparison)) { $score += 5 }

    if ($Path.EndsWith('.ps1', $comparison)) {
        $score += 5
        if ($Path.EndsWith('.Tests.ps1', $comparison)) { $score += 50 }
    }

    if ($Path.IndexOf('Module', $comparison) -ge 0 -or
        $Path.IndexOf('Orchestrator', $comparison) -ge 0 -or
        $Path.IndexOf('Agent', $comparison) -ge 0) {
        $score += 15
    }

    if ($Path.EndsWith('.system.txt', $comparison)) { $score += 10 }

    if ($Path.IndexOf('Program', $comparison) -ge 0 -or
        $Path.IndexOf('Startup', $comparison) -ge 0) {
        $score -= 10
    }

    $score -= (Get-RelevanceScore $Path)
    $score
}

function Find-SourceFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$Filter = '*.cs'
    )

    if (-not (Test-Path $RepoRoot -PathType Container)) {
        return @()
    }

    $files = @()
    try {
        $files = @(git -C $RepoRoot ls-files $Filter 2>$null | ForEach-Object { Join-Path $RepoRoot $_ })
    } catch {
        # Fallback if not a git repo or git fails
    }

    if ($files.Count -eq 0) {
        $files = @(Get-ChildItem $RepoRoot -Filter $Filter -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/](obj|bin|\.git|node_modules)[\\/]' } |
            ForEach-Object { $_.FullName })
    }

    return $files
}

function Search-Files {
    param ([Parameter(Mandatory)]$Pattern)

    if ($Pattern -is [Array]) {
        return ($Pattern | ForEach-Object { Search-Files $_ }) | Select-Object -Unique
    }

    # Optimisation: Pre-compile regex and avoid pipeline overhead
    try {
        $regex = [regex]::new($Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    } catch {
        Write-Warning "Invalid regex pattern: $Pattern"
        return @()
    }

    $files = git ls-files
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($file in $files) {
        if ($regex.IsMatch($file)) {
            $score = Score-File $file
            $results.Add([PSCustomObject]@{ Path = $file; Score = $score })
        }
    }

    $results |
        Sort-Object Score -Descending |
        Select-Object -First 25 |
        ForEach-Object { $_.Path }
}

# G04 — Hybrid search: regex + semantic
function Search-Hybrid {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Query,
        [int]$TopK = 25,
        [float]$RegexWeight = 0.4,
        [float]$SemanticWeight = 0.6
    )

    $combined = @{}  # keyed by file path -> { Path, RegexScore, SemanticScore, CombinedScore }

    # Phase 1: Regex-based search via Search-Files
    try {
        # Escape special regex characters but allow basic word matching
        $regexResults = Search-Files -Pattern $Query
        if ($regexResults) {
            # Search-Files returns paths sorted by Score (descending)
            # Normalise: top result gets score 1.0, linearly decreasing
            $regexCount = @($regexResults).Count
            for ($i = 0; $i -lt $regexCount; $i++) {
                $path = $regexResults[$i]
                $normalizedScore = if ($regexCount -gt 1) {
                    1.0 - ($i / ($regexCount - 1))
                } else {
                    1.0
                }
                $combined[$path] = @{
                    Path          = $path
                    RegexScore    = [float]$normalizedScore
                    SemanticScore = 0.0
                    CombinedScore = 0.0
                }
            }
        }
    } catch {
        Write-Warning "Search-Hybrid: Regex search failed: $($_.Exception.Message)"
    }

    # Phase 2: Semantic search via Invoke-SemanticSearch
    try {
        $semanticResults = Invoke-SemanticSearch -Query $Query -TopK $TopK
        if ($semanticResults) {
            foreach ($sr in $semanticResults) {
                $path = $sr.File
                if (-not $path) { continue }

                $semanticScore = if ($sr.Similarity) { [float]$sr.Similarity } else { 0.0 }
                # Clamp to [0,1]
                if ($semanticScore -lt 0) { $semanticScore = 0.0 }
                if ($semanticScore -gt 1) { $semanticScore = 1.0 }

                if ($combined.ContainsKey($path)) {
                    # File already found by regex — update semantic score (take the max if multiple chunks)
                    if ($semanticScore -gt $combined[$path].SemanticScore) {
                        $combined[$path].SemanticScore = $semanticScore
                    }
                } else {
                    $combined[$path] = @{
                        Path          = $path
                        RegexScore    = 0.0
                        SemanticScore = $semanticScore
                        CombinedScore = 0.0
                    }
                }
            }
        }
    } catch {
        Write-Warning "Search-Hybrid: Semantic search failed: $($_.Exception.Message)"
    }

    if ($combined.Count -eq 0) {
        return @()
    }

    # Phase 3: Compute combined score and rank
    foreach ($key in $combined.Keys) {
        $entry = $combined[$key]
        $entry.CombinedScore = ($RegexWeight * $entry.RegexScore) + ($SemanticWeight * $entry.SemanticScore)
    }

    # Return top-K results sorted by combined score descending
    $sorted = $combined.Values |
        Sort-Object { $_.CombinedScore } -Descending |
        Select-Object -First $TopK

    $sorted | ForEach-Object {
        [PSCustomObject]@{
            Path          = $_.Path
            RegexScore    = [Math]::Round($_.RegexScore, 4)
            SemanticScore = [Math]::Round($_.SemanticScore, 4)
            CombinedScore = [Math]::Round($_.CombinedScore, 4)
        }
    }
}

function Open-File {
    param ([Parameter(Mandatory)][string]$Path, [int]$MaxLines = 400)

    if (-not (Test-Path $Path)) { return "FILE_NOT_FOUND" }

    # Validate that the resolved path is within the repository root
    try {
        $repoRoot = (Resolve-Path "$PSScriptRoot/.." -ErrorAction Stop).Path
        # Normalize repo root to have consistent separators
        $repoRoot = $repoRoot.Replace('\', '/')

        $resolvedPaths = Convert-Path -Path $Path -ErrorAction Stop

        foreach ($resPath in $resolvedPaths) {
            $p = $resPath.Replace('\', '/')

            # Ensure the path starts with the repo root directory
            # append / to repoRoot to ensure we don't match partial directory names
            $rootCheck = $repoRoot
            if (-not $rootCheck.EndsWith('/')) {
                $rootCheck += '/'
            }

            if (-not $p.StartsWith($rootCheck) -and $p -ne $repoRoot) {
                return "ACCESS_DENIED"
            }
        }

        Mark-Relevant $Path
        (Get-Content -Path $resolvedPaths -TotalCount $MaxLines) -join "`n"
    } catch {
        return "FILE_NOT_FOUND"
    }
}

function Show-Diff {
    git --no-pager diff
}
