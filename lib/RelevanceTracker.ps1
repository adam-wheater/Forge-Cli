$Global:FileRelevance = @{}

function Mark-Relevant {
    param ($Path)
    $Global:FileRelevance[$Path] = ($Global:FileRelevance[$Path] + 1)
}

function Get-RelevanceScore {
    param ($Path)
    $Global:FileRelevance[$Path] ?? 0
}
