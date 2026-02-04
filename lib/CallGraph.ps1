function Get-ConstructorDependencies {
    param ($Path)
    if (-not (Test-Path $Path)) { return @() }

    $content = Get-Content $Path -Raw
    $matches = Select-String -InputObject $content -Pattern 'public\s+\w+\s*\(([^)]*)\)' -AllMatches

    $deps = @()
    foreach ($m in $matches.Matches) {
        $params = $m.Groups[1].Value -split ','
        foreach ($p in $params) {
            $type = ($p.Trim() -split '\s+')[0]
            if ($type) { $deps += $type }
        }
    }

    $deps | Select-Object -Unique
}
