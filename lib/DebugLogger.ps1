$Global:DebugMode = $false
$Global:LogRoot = Join-Path (Get-Location) "logs"

function Init-Debug {
    param ([Parameter(Mandatory)][bool]$Enabled)
    $Global:DebugMode = $Enabled
    if ($Enabled -and -not (Test-Path $Global:LogRoot)) {
        New-Item -ItemType Directory -Path $Global:LogRoot | Out-Null
    }
}

function Write-DebugLog {
    param ($Category, $Content)
    if (-not $Global:DebugMode) { return }

    # Sanitize category to prevent directory traversal
    $safeCategory = $Category -replace '[^a-zA-Z0-9_\-]', '_'

    $ts = Get-Date -Format "yyyyMMdd-HHmmss-fff"
    $file = Join-Path $Global:LogRoot "$ts-$safeCategory.log"

    # Verify the resolved path is still under LogRoot
    $resolvedPath = [System.IO.Path]::GetFullPath($file)
    $resolvedRoot = [System.IO.Path]::GetFullPath($Global:LogRoot)
    if (-not $resolvedPath.StartsWith($resolvedRoot)) {
        Write-Warning "DebugLog path traversal blocked: $file"
        return
    }

    $Content | Out-File $file -Encoding utf8
}
