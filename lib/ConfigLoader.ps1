$Global:ForgeConfig = @{}

# Default configuration values — used when no config file is present
$script:ConfigDefaults = @{
    maxLoops              = 8
    maxAgentIterations    = 20
    maxSearches           = 6
    maxOpens              = 5
    maxTotalTokens        = 200000
    maxIterationTokens    = 40000
    maxCostGBP            = 25.00
    promptCostPer1K       = 0.002
    completionCostPer1K   = 0.006
    memoryBackend         = "local"
    redisConnectionString = ""
    embeddingModel        = "text-embedding-3-small"
    builderDeployment     = ""
    judgeDeployment       = ""
    reviewerDeployment    = ""
    debugMode             = $false
    interactiveMode       = $false
    dryRun                = $false
}

# Env var name → config key mapping
$script:EnvVarMap = @{
    FORGE_MAX_LOOPS              = "maxLoops"
    FORGE_MAX_AGENT_ITERATIONS   = "maxAgentIterations"
    FORGE_MAX_SEARCHES           = "maxSearches"
    FORGE_MAX_OPENS              = "maxOpens"
    FORGE_MAX_TOTAL_TOKENS       = "maxTotalTokens"
    FORGE_MAX_ITERATION_TOKENS   = "maxIterationTokens"
    FORGE_MAX_COST_GBP           = "maxCostGBP"
    FORGE_PROMPT_COST_PER_1K     = "promptCostPer1K"
    FORGE_COMPLETION_COST_PER_1K = "completionCostPer1K"
    FORGE_MEMORY_BACKEND         = "memoryBackend"
    REDIS_CONNECTION_STRING      = "redisConnectionString"
    FORGE_EMBEDDING_MODEL        = "embeddingModel"
    FORGE_BUILDER_DEPLOYMENT     = "builderDeployment"
    FORGE_JUDGE_DEPLOYMENT       = "judgeDeployment"
    FORGE_REVIEWER_DEPLOYMENT    = "reviewerDeployment"
    FORGE_DEBUG_MODE             = "debugMode"
    FORGE_INTERACTIVE_MODE       = "interactiveMode"
    FORGE_DRY_RUN                = "dryRun"
}

function Load-ForgeConfig {
    param (
        [string]$ConfigPath = (Join-Path $PSScriptRoot ".." "forge.config.json")
    )

    # Start with defaults
    $config = @{}
    foreach ($key in $script:ConfigDefaults.Keys) {
        $config[$key] = $script:ConfigDefaults[$key]
    }

    # Load from config file if it exists
    if (Test-Path $ConfigPath) {
        try {
            $fileContent = Get-Content $ConfigPath -Raw | ConvertFrom-Json
            foreach ($prop in $fileContent.PSObject.Properties) {
                if ($config.ContainsKey($prop.Name)) {
                    $config[$prop.Name] = $prop.Value
                }
            }
        } catch {
            Write-Warning "Failed to load config from '${ConfigPath}': $($_.Exception.Message)"
        }
    }

    # Apply env var overrides (env vars take precedence)
    foreach ($envVar in $script:EnvVarMap.Keys) {
        $envValue = [System.Environment]::GetEnvironmentVariable($envVar)
        if ($null -ne $envValue -and $envValue -ne "") {
            $configKey = $script:EnvVarMap[$envVar]
            $defaultValue = $script:ConfigDefaults[$configKey]

            # Convert env var string to the correct type based on the default value type
            try {
                if ($defaultValue -is [int]) {
                    $config[$configKey] = [int]$envValue
                } elseif ($defaultValue -is [double]) {
                    $config[$configKey] = [double]$envValue
                } elseif ($defaultValue -is [bool]) {
                    $config[$configKey] = ($envValue -eq "true" -or $envValue -eq "1")
                } else {
                    $config[$configKey] = $envValue
                }
            } catch {
                Write-Warning "Invalid value '$envValue' for env var $envVar (expected $($defaultValue.GetType().Name)) — using default"
            }
        }
    }

    $Global:ForgeConfig = $config
    return $config
}
