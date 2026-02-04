function Get-Imports {
    param ($Path)
    if (-not (Test-Path $Path)) { return @() }

    Get-Content $Path |
        Where-Object { $_ -match '^\s*using\s+' } |
        ForEach-Object {
            ($_ -replace '^\s*using\s+', '' -replace ';', '').Trim()
        } |
        Select-Object -Unique
}
