function Get-ConstructorDependencies {
    param ([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return @() }

    # Bolt: Optimized to use native .NET ReadAllText which is faster than Get-Content
    $fullPath = Convert-Path $Path
    $content = [System.IO.File]::ReadAllText($fullPath)

    # Bolt: [regex]::Matches is significantly faster than Select-String
    $matches = [regex]::Matches($content, 'public\s+\w+\s*\(([^)]*)\)')

    # Bolt: Use HashSet for O(1) deduplication and to avoid O(N^2) array concatenation (+=)
    $deps = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

    foreach ($m in $matches) {
        # Bolt: Native .Split is faster than PowerShell -split
        $params = $m.Groups[1].Value.Split(',', [System.StringSplitOptions]::RemoveEmptyEntries)
        foreach ($p in $params) {
            $pTrimmed = $p.Trim()
            if ($pTrimmed.Length -gt 0) {
                # Bolt: Extract the type using fast native char split
                $type = $pTrimmed.Split([char[]]@(' ', "`t", "`r", "`n"), [System.StringSplitOptions]::RemoveEmptyEntries)[0]
                if ($type) {
                    [void]$deps.Add($type)
                }
            }
        }
    }

    [string[]]$deps
}
