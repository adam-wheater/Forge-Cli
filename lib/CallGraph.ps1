function Get-ConstructorDependencies {
    param ([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return @() }

    # Bolt Optimization: ReadAllText is faster than Get-Content
    # Use Convert-Path to ensure relative paths resolve correctly in the .NET context
    $resolvedPath = Convert-Path $Path
    $content = [System.IO.File]::ReadAllText($resolvedPath)
    # Bolt Optimization: native [regex]::Matches is faster than Select-String pipeline. Use IgnoreCase to match Select-String default behavior.
    $matches = [regex]::Matches($content, 'public\s+\w+\s*\(([^)]*)\)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

    if ($matches.Count -eq 0) {
        return @()
    }

    # Bolt Optimization: HashSet O(1) adds and unique guarantee instead of += array concat
    $deps = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $splitChars = [char[]](' ', "`t", "`n", "`r")

    foreach ($m in $matches) {
        # Bolt Optimization: Native string split is faster than -split operator
        $params = $m.Groups[1].Value.Split(',', [System.StringSplitOptions]::RemoveEmptyEntries)
        foreach ($p in $params) {
            $parts = $p.TrimStart().Split($splitChars, [System.StringSplitOptions]::RemoveEmptyEntries)
            if ($parts.Length -gt 0) {
                [void]$deps.Add($parts[0])
            }
        }
    }

    return @($deps)
}
