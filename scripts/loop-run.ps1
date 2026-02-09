param(
    [int]$MaxAttempts = 6
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir
for ($i = 1; $i -le $MaxAttempts; $i++) {
    Write-Host "`n=== Attempt $i / $MaxAttempts ==="
    Set-Location $root
    $repoPath = Join-Path $root 'tmp-sample-repo'
    if (Test-Path $repoPath) {
        Remove-Item -LiteralPath $repoPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    try {
        # Use local fixture repo as source for loop runs when no remote is provided
        $repoUrl = Join-Path $root 'tests\fixtures\SampleApi'
        & (Join-Path $root 'run.ps1') -RepoUrl $repoUrl -MaxLoops 1 -DebugMode
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
