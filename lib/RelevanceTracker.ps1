$Global:FileRelevance = @{}

function Mark-Relevant {
    param ([Parameter(Mandatory)][string]$Path)
    $Global:FileRelevance[$Path] = ($Global:FileRelevance[$Path] + 1)
}

function Get-RelevanceScore {
    param ([Parameter(Mandatory)][string]$Path)
    $Global:FileRelevance[$Path] ?? 0
}
