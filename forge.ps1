<#
.SYNOPSIS
    Forge Agent — General-purpose orchestrated agent framework for code tasks.
.DESCRIPTION
    Accepts a high-level instruction, decomposes it into subtasks using an LLM orchestrator,
    retrieves relevant code context via embeddings, and dispatches workers to execute each task.
    Supports any code task: analysis, bug fixes, refactoring, test generation, and more.
.PARAMETER Instruction
    The high-level instruction describing what you want done (required).
.PARAMETER RepoPath
    Path to the local repository. Defaults to current directory.
.PARAMETER Branch
    Optional branch name to create for changes.
.PARAMETER MaxSteps
    Maximum task decomposition steps. Must be 1-100. Default: 20.
.PARAMETER DebugMode
    Enable verbose debug logging to tmp-logs/.
.PARAMETER DryRun
    Decompose the instruction and show the task plan without executing.
.PARAMETER ConfigPath
    Path to forge.config.json. Default: forge.config.json in script root.
.PARAMETER CIMode
    CI mode: structured JSON output, no prompts, exit codes.
.PARAMETER SkipEmbeddings
    Skip building the embedding index (faster startup, no semantic search).
#>
param (
    [Parameter(Mandatory)][string]$Instruction,
    [string]$RepoPath = ".",
    [string]$Branch = "",
    [ValidateRange(1, 100)][int]$MaxSteps = 20,
    [switch]$DebugMode,
    [switch]$DryRun,
    [string]$ConfigPath = "",
    [switch]$CIMode,
    [switch]$SkipEmbeddings,
    [string]$TaskType = "auto"
)

$ErrorActionPreference = "Stop"

# Auto-load .env file (set vars only if not already in environment)
$envFile = Join-Path $PSScriptRoot ".env"
if (Test-Path $envFile) {
    foreach ($line in Get-Content $envFile) {
        $line = $line.Trim()
        if ($line -eq "" -or $line.StartsWith("#")) { continue }
        if ($line -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            $varName = $Matches[1]
            $varValue = $Matches[2] -replace "^[`"']|[`"']$", ''
            if (-not [System.Environment]::GetEnvironmentVariable($varName)) {
                [System.Environment]::SetEnvironmentVariable($varName, $varValue)
            }
        }
    }
}

# Load configuration
. "$PSScriptRoot/lib/ConfigLoader.ps1"
if ($ConfigPath -and -not (Test-Path $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}
$configFile = if ($ConfigPath) { $ConfigPath } else { Join-Path $PSScriptRoot "forge.config.json" }
$config = Load-ForgeConfig -ConfigPath $configFile

# Apply CLI overrides to config
if ($DebugMode) { $config.debugMode = $true }
if ($DryRun)    { $config.dryRun = $true }
$Global:ForgeConfig = $config

# Validate required environment variables
$requiredVars = @("AZURE_OPENAI_ENDPOINT", "AZURE_OPENAI_API_KEY", "AZURE_OPENAI_API_VERSION")
foreach ($var in $requiredVars) {
    if (-not [System.Environment]::GetEnvironmentVariable($var)) {
        # Check if a deployment is configured in config (may not need env vars for everything)
        if ($var -eq "AZURE_OPENAI_ENDPOINT") {
            throw "Missing required environment variable: $var"
        }
    }
}

# Ensure at least one deployment is available
$hasDeployment = $env:BUILDER_DEPLOYMENT -or
    ($config.ContainsKey('builderDeployment') -and $config.builderDeployment) -or
    ($config.ContainsKey('orchestratorDeployment') -and $config.orchestratorDeployment) -or
    ($config.ContainsKey('workerDeployment') -and $config.workerDeployment)
if (-not $hasDeployment) {
    throw "No deployment configured. Set BUILDER_DEPLOYMENT env var or builderDeployment/orchestratorDeployment/workerDeployment in config."
}

# Resolve repo path
$RepoPath = (Resolve-Path $RepoPath -ErrorAction Stop).Path
if (-not (Test-Path (Join-Path $RepoPath ".git"))) {
    Write-Warning "No .git directory found in $RepoPath — some features (git memory, embeddings) may not work"
}

# Load all library modules
. "$PSScriptRoot/lib/DebugLogger.ps1"
. "$PSScriptRoot/lib/MetricsTracker.ps1"
. "$PSScriptRoot/lib/DecisionTrace.ps1"
. "$PSScriptRoot/lib/RedisCache.ps1"
. "$PSScriptRoot/lib/TaskOrchestrator.ps1"

# Set global repo root for tools
$Global:RepoRoot = $RepoPath

# Initialize subsystems
Push-Location $RepoPath
try {
    # Initialize repo memory
    Write-Host "Initializing repo memory..." -ForegroundColor Gray
    Initialize-RepoMemory -RepoRoot $RepoPath

    # Initialize metrics and tracing
    if (Get-Command Initialize-Metrics -ErrorAction SilentlyContinue) {
        Initialize-Metrics
    }
    if ($config.debugMode -and (Get-Command Initialize-DecisionTrace -ErrorAction SilentlyContinue)) {
        Initialize-DecisionTrace
    }

    # Build embedding index (unless skipped)
    if (-not $SkipEmbeddings) {
        Write-Host "Building embedding index..." -ForegroundColor Gray
        try {
            if ($Global:EmbeddingCache.Count -eq 0) {
                Build-EmbeddingIndex -RepoRoot $RepoPath
            } else {
                Update-EmbeddingIndex -RepoRoot $RepoPath
            }
            Write-Host "  Indexed $($Global:EmbeddingCache.Count) chunks" -ForegroundColor Gray
        } catch {
            Write-Warning "Embedding index build failed: $($_.Exception.Message) — continuing without semantic search"
        }
    }

    # Create session (Redis if available)
    try {
        if (Get-Command New-ForgeSession -ErrorAction SilentlyContinue) {
            $Global:OrchestratorSessionId = New-ForgeSession -RepoName (Split-Path $RepoPath -Leaf)
        }
    } catch {
        # Session tracking is optional
    }

    # Create branch if requested
    if ($Branch -and -not $DryRun) {
        try {
            $currentBranch = git -C $RepoPath rev-parse --abbrev-ref HEAD 2>$null
            if ($currentBranch -ne $Branch) {
                git -C $RepoPath checkout -b $Branch 2>$null
                Write-Host "Created branch: $Branch" -ForegroundColor Green
            }
        } catch {
            Write-Warning "Failed to create branch '$Branch': $($_.Exception.Message)"
        }
    }

    # Apply config-driven overrides
    $maxStepsOverride = if ($config.ContainsKey('maxTaskSteps') -and $config.maxTaskSteps -gt 0) {
        [math]::Min($MaxSteps, $config.maxTaskSteps)
    } else {
        $MaxSteps
    }

    # Run the orchestration
    $result = Start-TaskOrchestration `
        -Instruction $Instruction `
        -MaxSteps $maxStepsOverride `
        -TaskType $TaskType `
        -DryRun:$DryRun

    # Output result
    if ($CIMode) {
        # CI mode: structured JSON output
        $result | ConvertTo-Json -Depth 10
    } else {
        # Console summary
        Write-Host ""
        if ($result.success) {
            Write-Host "SUCCESS" -ForegroundColor Green
        } else {
            Write-Host "COMPLETED WITH ISSUES" -ForegroundColor Yellow
        }

        if ($result.learnings) {
            Write-Host "`n$($result.learnings)" -ForegroundColor Gray
        }
    }

    # Save metrics
    if (Get-Command Save-Metrics -ErrorAction SilentlyContinue) {
        Save-Metrics
    }

    # Clean up session
    if ($Global:OrchestratorSessionId -and (Get-Command Remove-ForgeSession -ErrorAction SilentlyContinue)) {
        Remove-ForgeSession -SessionId $Global:OrchestratorSessionId
    }

    # Exit code for CI
    if ($CIMode) {
        exit $(if ($result.success) { 0 } else { 1 })
    }

} finally {
    Pop-Location
}
