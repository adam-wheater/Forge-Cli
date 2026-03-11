function Get-Imports {
    param ([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return @() }

    # Optimisation: Use native .NET for file reading and regex to avoid PowerShell pipeline overhead
    $content = [System.IO.File]::ReadAllText((Convert-Path $Path))
    $matches = [regex]::Matches($content, '(?m)^\s*using\s+([^;]+);')

    # Optimisation: Use HashSet for unique collection instead of Select-Object -Unique pipeline
    $deps = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($m in $matches) {
        [void]$deps.Add($m.Groups[1].Value.Trim())
    }

    return @($deps)
}
