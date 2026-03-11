function Get-ConstructorDependencies {
    param ([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return @() }

    # Optimisation: Use native .NET for file reading and regex to avoid PowerShell pipeline overhead
    $content = [System.IO.File]::ReadAllText((Convert-Path $Path))
    $matches = [regex]::Matches($content, 'public\s+\w+\s*\(([^)]*)\)')

    # Optimisation: Use HashSet for unique collection without O(n^2) array concatenation
    $deps = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($m in $matches) {
        $paramStr = $m.Groups[1].Value.Trim()
        if ($paramStr) {
            # Optimisation: Use native string Split instead of -split operator
            $params = $paramStr.Split(',')
            foreach ($p in $params) {
                $tokens = [System.Text.RegularExpressions.Regex]::Split($p.Trim(), '\s+')
                if ($tokens.Count -gt 0 -and $tokens[0]) {
                    [void]$deps.Add($tokens[0])
                }
            }
        }
    }

    return @($deps)
}
