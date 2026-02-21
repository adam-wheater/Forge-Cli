BeforeAll {
    . "$PSScriptRoot/../lib/ConfigLoader.ps1"
}

Describe 'Load-ForgeConfig' {
    BeforeEach {
        $Global:ForgeConfig = @{}
        # Clear any forge-related env vars
        [System.Environment]::SetEnvironmentVariable("FORGE_MAX_LOOPS", $null)
        [System.Environment]::SetEnvironmentVariable("FORGE_MEMORY_BACKEND", $null)
        [System.Environment]::SetEnvironmentVariable("REDIS_CONNECTION_STRING", $null)
        [System.Environment]::SetEnvironmentVariable("FORGE_DEBUG_MODE", $null)
        [System.Environment]::SetEnvironmentVariable("FORGE_MAX_COST_GBP", $null)
        [System.Environment]::SetEnvironmentVariable("FORGE_MAX_TOTAL_TOKENS", $null)
    }

    Context 'When no config file exists' {
        It 'Returns defaults' {
            $config = Load-ForgeConfig -ConfigPath "/tmp/nonexistent-forge-config.json"
            $config.maxLoops | Should -Be 8
            $config.maxAgentIterations | Should -Be 20
            $config.maxTotalTokens | Should -Be 200000
            $config.maxIterationTokens | Should -Be 40000
            $config.maxCostGBP | Should -Be 25.00
            $config.memoryBackend | Should -Be "local"
            $config.debugMode | Should -Be $false
            $config.dryRun | Should -Be $false
        }

        It 'Sets $Global:ForgeConfig' {
            Load-ForgeConfig -ConfigPath "/tmp/nonexistent-forge-config.json"
            $Global:ForgeConfig.maxLoops | Should -Be 8
            $Global:ForgeConfig.memoryBackend | Should -Be "local"
        }
    }

    Context 'When config file exists' {
        BeforeEach {
            $script:tempConfigPath = Join-Path ([System.IO.Path]::GetTempPath()) "forge-test-config.json"
            @{
                maxLoops        = 12
                memoryBackend   = "redis"
                debugMode       = $true
                maxCostGBP      = 50.00
            } | ConvertTo-Json | Out-File $script:tempConfigPath -Encoding utf8
        }

        AfterEach {
            if (Test-Path $script:tempConfigPath) {
                Remove-Item $script:tempConfigPath -Force
            }
        }

        It 'Loads values from file' {
            $config = Load-ForgeConfig -ConfigPath $script:tempConfigPath
            $config.maxLoops | Should -Be 12
            $config.memoryBackend | Should -Be "redis"
            $config.debugMode | Should -Be $true
            $config.maxCostGBP | Should -Be 50.00
        }

        It 'Preserves defaults for keys not in file' {
            $config = Load-ForgeConfig -ConfigPath $script:tempConfigPath
            $config.maxAgentIterations | Should -Be 20
            $config.maxTotalTokens | Should -Be 200000
            $config.embeddingModel | Should -Be "text-embedding-3-small"
        }
    }

    Context 'When env var overrides are set' {
        It 'Env vars take precedence over file values' {
            $script:tempConfigPath = Join-Path ([System.IO.Path]::GetTempPath()) "forge-test-config-env.json"
            @{
                maxLoops      = 12
                memoryBackend = "local"
            } | ConvertTo-Json | Out-File $script:tempConfigPath -Encoding utf8

            [System.Environment]::SetEnvironmentVariable("FORGE_MAX_LOOPS", "99")
            [System.Environment]::SetEnvironmentVariable("FORGE_MEMORY_BACKEND", "redis")

            $config = Load-ForgeConfig -ConfigPath $script:tempConfigPath
            $config.maxLoops | Should -Be 99
            $config.memoryBackend | Should -Be "redis"

            Remove-Item $script:tempConfigPath -Force
        }

        It 'Converts boolean env vars correctly' {
            [System.Environment]::SetEnvironmentVariable("FORGE_DEBUG_MODE", "true")
            $config = Load-ForgeConfig -ConfigPath "/tmp/nonexistent-forge-config.json"
            $config.debugMode | Should -Be $true
        }

        It 'Converts numeric env vars correctly' {
            [System.Environment]::SetEnvironmentVariable("FORGE_MAX_COST_GBP", "75.50")
            $config = Load-ForgeConfig -ConfigPath "/tmp/nonexistent-forge-config.json"
            $config.maxCostGBP | Should -Be 75.50
        }
    }

    Context 'When config file is invalid JSON' {
        It 'Falls back to defaults gracefully' {
            $script:tempBadPath = Join-Path ([System.IO.Path]::GetTempPath()) "forge-test-bad.json"
            "this is not valid json {{{" | Out-File $script:tempBadPath -Encoding utf8

            $config = Load-ForgeConfig -ConfigPath $script:tempBadPath
            $config.maxLoops | Should -Be 8
            $config.memoryBackend | Should -Be "local"

            Remove-Item $script:tempBadPath -Force
        }
    }
}

Describe 'Test-ForgeConfig' {
    BeforeEach {
        # Setup valid base config
        $script:validConfig = @{
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
            embeddingModel        = "text-embedding-3-small"
            builderDeployment     = "builder"
            judgeDeployment       = "judge"
        }
        # Mock env vars
        $env:AZURE_OPENAI_ENDPOINT = "https://example.com"
        $env:BUILDER_DEPLOYMENT = "builder"
        $env:JUDGE_DEPLOYMENT = "judge"
    }

    AfterEach {
        $env:AZURE_OPENAI_ENDPOINT = $null
        $env:BUILDER_DEPLOYMENT = $null
        $env:JUDGE_DEPLOYMENT = $null
    }

    It 'Passes validation for valid config' {
        $warnings = Test-ForgeConfig $script:validConfig
        $warnings.Count | Should -Be 0
    }

    It 'Warns on non-positive numeric values' {
        $badConfig = $script:validConfig.Clone()
        $badConfig.maxLoops = 0
        $badConfig.maxCostGBP = -5.00

        $warnings = Test-ForgeConfig $badConfig
        $warnings | Should -Match "maxLoops must be greater than 0"
        $warnings | Should -Match "maxCostGBP must be greater than 0"
    }

    It 'Warns when maxIterationTokens exceeds maxTotalTokens' {
        $badConfig = $script:validConfig.Clone()
        $badConfig.maxIterationTokens = 300000
        $badConfig.maxTotalTokens = 200000

        $warnings = Test-ForgeConfig $badConfig
        $warnings | Should -Match "maxIterationTokens .* exceeds maxTotalTokens"
    }

    It 'Warns on invalid memoryBackend' {
        $badConfig = $script:validConfig.Clone()
        $badConfig.memoryBackend = "invalid_backend"

        $warnings = Test-ForgeConfig $badConfig
        $warnings | Should -Match "memoryBackend must be 'local' or 'redis'"
    }

    It 'Warns on missing redisConnectionString for redis backend' {
        $badConfig = $script:validConfig.Clone()
        $badConfig.memoryBackend = "redis"
        $badConfig.redisConnectionString = ""

        $warnings = Test-ForgeConfig $badConfig
        $warnings | Should -Match "memoryBackend is 'redis' but redisConnectionString is empty"
    }

    It 'Warns on invalid endpoint URL' {
        $env:AZURE_OPENAI_ENDPOINT = "http://insecure.com"

        $warnings = Test-ForgeConfig $script:validConfig
        $warnings | Should -Match "AZURE_OPENAI_ENDPOINT should start with https://"
    }

    It 'Warns on missing embedding model when endpoint is set' {
        $badConfig = $script:validConfig.Clone()
        $badConfig.embeddingEndpoint = "https://embed.com"
        $badConfig.embeddingModel = ""

        $warnings = Test-ForgeConfig $badConfig
        $warnings | Should -Match "embeddingEndpoint is set but embeddingModel is empty"
    }

    It 'Warns on missing deployments' {
        $env:BUILDER_DEPLOYMENT = $null
        $badConfig = $script:validConfig.Clone()
        $badConfig.builderDeployment = ""

        $warnings = Test-ForgeConfig $badConfig
        $warnings | Should -Match "No builder deployment configured"
    }
}

Describe 'Load-ForgeConfig Validation' {
    BeforeEach {
        $script:validConfig = @{
            maxLoops              = 8
            maxAgentIterations    = 20
            maxTotalTokens        = 200000
            maxCostGBP            = 25.00
            memoryBackend         = "local"
        }
        $script:tempConfigPath = Join-Path ([System.IO.Path]::GetTempPath()) "forge-test-validation.json"
        $script:validConfig | ConvertTo-Json | Out-File $script:tempConfigPath -Encoding utf8

        # Clear env vars
        [System.Environment]::SetEnvironmentVariable("FORGE_MAX_LOOPS", $null)
        [System.Environment]::SetEnvironmentVariable("FORGE_MAX_TOTAL_TOKENS", $null)
        [System.Environment]::SetEnvironmentVariable("FORGE_MAX_COST_GBP", $null)
        [System.Environment]::SetEnvironmentVariable("FORGE_MAX_ITERATION_TOKENS", $null)

        # Mock env vars for deployment checks
        $env:AZURE_OPENAI_ENDPOINT = "https://example.com"
        $env:BUILDER_DEPLOYMENT = "builder"
        $env:JUDGE_DEPLOYMENT = "judge"
    }

    AfterEach {
        if (Test-Path $script:tempConfigPath) {
            Remove-Item $script:tempConfigPath -Force
        }
        $env:AZURE_OPENAI_ENDPOINT = $null
        $env:BUILDER_DEPLOYMENT = $null
        $env:JUDGE_DEPLOYMENT = $null
    }

    It 'Throws on invalid maxLoops (critical)' {
        [System.Environment]::SetEnvironmentVariable("FORGE_MAX_LOOPS", "-1")

        { Load-ForgeConfig -ConfigPath $script:tempConfigPath } | Should -Throw
    }

    It 'Throws on invalid maxTotalTokens (critical)' {
        [System.Environment]::SetEnvironmentVariable("FORGE_MAX_TOTAL_TOKENS", "-100")

        { Load-ForgeConfig -ConfigPath $script:tempConfigPath } | Should -Throw
    }

    It 'Throws on invalid maxCostGBP (critical)' {
        [System.Environment]::SetEnvironmentVariable("FORGE_MAX_COST_GBP", "-50.00")

        { Load-ForgeConfig -ConfigPath $script:tempConfigPath } | Should -Throw
    }

    It 'Does not throw on non-critical warnings' {
        # maxIterationTokens > maxTotalTokens is a warning, not critical
        [System.Environment]::SetEnvironmentVariable("FORGE_MAX_ITERATION_TOKENS", "300000")

        { $config = Load-ForgeConfig -ConfigPath $script:tempConfigPath } | Should -Not -Throw
    }
}

AfterAll {
    $Global:ForgeConfig = @{}
    [System.Environment]::SetEnvironmentVariable("FORGE_MAX_LOOPS", $null)
    [System.Environment]::SetEnvironmentVariable("FORGE_MEMORY_BACKEND", $null)
    [System.Environment]::SetEnvironmentVariable("REDIS_CONNECTION_STRING", $null)
    [System.Environment]::SetEnvironmentVariable("FORGE_DEBUG_MODE", $null)
    [System.Environment]::SetEnvironmentVariable("FORGE_MAX_COST_GBP", $null)
    [System.Environment]::SetEnvironmentVariable("FORGE_MAX_TOTAL_TOKENS", $null)
}
