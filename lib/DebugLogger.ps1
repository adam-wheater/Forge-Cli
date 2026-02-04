$Global:DebugMode = $false
$Global:LogRoot = Join-Path (Get-Location) "logs"

function Init-Debug {
    param ([bool]$Enabled)
    $Global:DebugMode = $Enabled
    if ($Enabled -and -not (Test-Path $Global:LogRoot)) {
        New-Item -ItemType Directory -Path $Global:LogRoot | Out-Null
    }
}

function Write-DebugLog {
    param ($Category, $Content)
    if (-not $Global:DebugMode) { return }

    $ts = Get-Date -Format "yyyyMMdd-HHmmss-fff"
    $file = Join-Path $Global:LogRoot "$ts-$Category.log"
    $Content | Out-File $file -Encoding utf8
}
