function Get-ConstructorDependencies {
    param ([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return @() }

    # Resolve full path since .NET file API requires it
    $fullPath = Convert-Path $Path

    # ⚡ Bolt Optimization: Use native .NET ReadAllText, Matches, and HashSet
    # for significant performance improvement over Get-Content and Select-String pipelines.
    $content = [System.IO.File]::ReadAllText($fullPath)
    $matches = [regex]::Matches($content, 'public\s+\w+\s*\(([^)]*)\)')

    $deps = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($m in $matches) {
        $params = [regex]::Split($m.Groups[1].Value, ',')
        foreach ($p in $params) {
            $type = ([regex]::Split($p.Trim(), '\s+'))[0]
            if ($type) { [void]$deps.Add($type) }
        }
    }

    return [string[]]$deps
}
