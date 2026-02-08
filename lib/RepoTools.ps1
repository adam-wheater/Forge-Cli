. "$PSScriptRoot/RelevanceTracker.ps1"

function Score-File {
    param ([Parameter(Mandatory)][string]$Path)

    $score = 0
    if ($Path -match 'Test|Tests') { $score += 50 }
    if ($Path -match 'Service|Controller|Manager|Repository|Repo') { $score += 15 }
    if ($Path -match '\.cs$') { $score += 5 }
    if ($Path -match '\.ps1$') { $score += 5 }
    if ($Path -match '\.Tests\.ps1$') { $score += 50 }
    if ($Path -match 'Module|Orchestrator|Agent') { $score += 15 }
    if ($Path -match '\.system\.txt$') { $score += 10 }
    if ($Path -match 'Program|Startup') { $score -= 10 }
    $score -= (Get-RelevanceScore $Path)
    $score
}

function Search-Files {
    param ([Parameter(Mandatory)]$Pattern)

    if ($Pattern -is [Array]) {
        return ($Pattern | ForEach-Object { Search-Files $_ }) | Select-Object -Unique
    }

    git ls-files |
        Where-Object { $_ -match $Pattern } |
        ForEach-Object {
            [PSCustomObject]@{ Path = $_; Score = (Score-File $_) }
        } |
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
    Mark-Relevant $Path
    (Get-Content $Path -TotalCount $MaxLines) -join "`n"
}

function Show-Diff {
    git --no-pager diff
}
