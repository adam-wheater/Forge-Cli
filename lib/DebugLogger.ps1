param()

function Init-Debug {
    param(
        [switch]$Enabled
    )
    try {
        $global:FORGE_DEBUG = $false
        if ($Enabled) { $global:FORGE_DEBUG = $true }

        # Ensure repo-root tmp-logs exists
        $repoRoot = (Resolve-Path "$PSScriptRoot\.." -ErrorAction SilentlyContinue).Path
        if (-not $repoRoot) { $repoRoot = Get-Location }
        $logDir = Join-Path $repoRoot 'tmp-logs'
        if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
        return $true
    } catch {
        return $false
    }
}

function Write-DebugLog {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][object]$Message
    )
    try {
        if (-not $global:FORGE_DEBUG) { return }
        $repoRoot = (Resolve-Path "$PSScriptRoot\.." -ErrorAction SilentlyContinue).Path
        if (-not $repoRoot) { $repoRoot = Get-Location }
        $logDir = Join-Path $repoRoot 'tmp-logs'
        if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }

        $ts = Get-Date -Format "yyyyMMddTHHmmssfff"
        $file = Join-Path $logDir "debug-$Key.log"
        $text = if ($Message -is [string]) { $Message } else { $Message | ConvertTo-Json -Depth 6 }
        "$ts `t $text" | Out-File -FilePath $file -Encoding utf8 -Append -Force
    } catch {
        return
    }
}

# Note: do not export module members when sourced as a script
