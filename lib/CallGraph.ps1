function Get-ConstructorDependencies {
    param ([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return @() }

    $content = Get-Content $Path -Raw
    $matches = [regex]::Matches($content, 'public\s+\w+\s*\(([^)]*)\)')

    # Optimisation: Use HashSet for fast unique collection, avoid += array concatenation
    $deps = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($m in $matches) {
        $params = $m.Groups[1].Value -split ','
        foreach ($p in $params) {
            $trimmed = $p.Trim()
            if (-not $trimmed) { continue }

            # Fast path: split by any whitespace character using regex, but take only the first item
            $type = ($trimmed -split '\s+')[0]
            if ($type) {
                $null = $deps.Add($type)
            }
        }
    }

    [string[]]$deps
}
