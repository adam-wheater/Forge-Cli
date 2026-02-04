. "$PSScriptRoot/RelevanceTracker.ps1"

function Score-File {
    param ($Path)

    $score = 0
    if ($Path -match 'Test|Tests') { $score += 50 }
    if ($Path -match 'Service|Controller|Manager|Repository|Repo') { $score += 15 }
    if ($Path -match '\.cs') { $score += 5 }
    if ($Path -match 'Program|Startup') { $score -= 10 }
    $score -= (Get-RelevanceScore $Path)
    $score
}

function Search-Files {
    param ($Pattern)

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

function Open-File {
    param ($Path, $MaxLines = 400)

    if (-not (Test-Path $Path)) { return "FILE_NOT_FOUND" }
    Mark-Relevant $Path
    (Get-Content $Path -TotalCount $MaxLines) -join "`n"
}

function Show-Diff {
    git --no-pager diff
}
