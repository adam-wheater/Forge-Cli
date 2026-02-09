param(
    [string]$RepoUrl,
    [int]$MaxAttempts = 6
)

if (-not $RepoUrl) {
    Write-Host "Usage: loop-run.ps1 -RepoUrl <git-url-or-local-path> [-MaxAttempts N]"
    exit 1
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir
for ($i = 1; $i -le $MaxAttempts; $i++) {
    Write-Host "`n=== Attempt $i / $MaxAttempts ==="
    Set-Location $root
    # Derive repo folder name from URL
    $repoName = ($RepoUrl -replace '\.git$','') -replace '.*/',''
    $repoPath = Join-Path $root $repoName
    if (Test-Path $repoPath) {
        Remove-Item -LiteralPath $repoPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    try {
        & (Join-Path $root 'run.ps1') -RepoUrl $RepoUrl -MaxLoops 1 -DebugMode
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Pipeline succeeded on attempt $i"
            exit 0
        }
    } catch {
        Write-Host "Run failed: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds 2
}

Write-Host "Reached max attempts ($MaxAttempts) without success"
exit 1
