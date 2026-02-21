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

    Context 'Validation' {
        It 'Throws on critical config error (maxLoops)' {
            [System.Environment]::SetEnvironmentVariable("FORGE_MAX_LOOPS", "-1")
            { Load-ForgeConfig -ConfigPath "/tmp/nonexistent-forge-config.json" } | Should -Throw "Config validation error: maxLoops must be greater than 0*"
        }

        It 'Throws on critical config error (maxTotalTokens)' {
            [System.Environment]::SetEnvironmentVariable("FORGE_MAX_TOTAL_TOKENS", "-1")
            { Load-ForgeConfig -ConfigPath "/tmp/nonexistent-forge-config.json" } | Should -Throw "Config validation error: maxTotalTokens must be greater than 0*"
        }

        It 'Throws on critical config error (maxCostGBP)' {
            [System.Environment]::SetEnvironmentVariable("FORGE_MAX_COST_GBP", "-1.5")
            { Load-ForgeConfig -ConfigPath "/tmp/nonexistent-forge-config.json" } | Should -Throw "Config validation error: maxCostGBP must be greater than 0*"
        }
    }
}

Describe 'Test-ForgeConfig' {
    BeforeEach {
        # Mock necessary env vars to avoid noise from global environment
        $env:BUILDER_DEPLOYMENT = "builder"
        $env:JUDGE_DEPLOYMENT = "judge"
        $env:AZURE_OPENAI_ENDPOINT = "https://example.com"
    }

    AfterEach {
        $env:BUILDER_DEPLOYMENT = $null
        $env:JUDGE_DEPLOYMENT = $null
        $env:AZURE_OPENAI_ENDPOINT = $null
    }

    It 'Returns warning for non-positive numeric values' {
        $config = @{
            maxLoops = 0
            maxTotalTokens = -1
            maxCostGBP = 0.0
        }
        $warnings = Test-ForgeConfig -Config $config
        $warnings | Should -Match "maxLoops must be greater than 0"
        $warnings | Should -Match "maxTotalTokens must be greater than 0"
        $warnings | Should -Match "maxCostGBP must be greater than 0"
    }

    It 'Returns warning when maxIterationTokens exceeds maxTotalTokens' {
        $config = @{
            maxIterationTokens = 100
            maxTotalTokens = 50
        }
        $warnings = Test-ForgeConfig -Config $config
        $warnings | Should -Match "maxIterationTokens .* exceeds maxTotalTokens"
    }

    It 'Returns warning for invalid memoryBackend' {
        $config = @{ memoryBackend = "invalid" }
        $warnings = Test-ForgeConfig -Config $config
        $warnings | Should -Match "memoryBackend must be 'local' or 'redis'"
    }

    It 'Returns warning for missing redisConnectionString' {
        $config = @{ memoryBackend = "redis"; redisConnectionString = "" }
        $warnings = Test-ForgeConfig -Config $config
        $warnings | Should -Match "memoryBackend is 'redis' but redisConnectionString is empty"
    }

    It 'Returns warning for invalid AZURE_OPENAI_ENDPOINT' {
        $env:AZURE_OPENAI_ENDPOINT = "http://insecure.com"
        $warnings = Test-ForgeConfig -Config @{}
        $warnings | Should -Match "AZURE_OPENAI_ENDPOINT should start with https://"
    }

    It 'Returns warning when embeddingEndpoint is not https' {
        $config = @{ embeddingEndpoint = "http://insecure.com" }
        $warnings = Test-ForgeConfig -Config $config
        $warnings | Should -Match "embeddingEndpoint should start with https://"
    }

    It 'Returns warning for inconsistent embedding config' {
        $config1 = @{ embeddingEndpoint = "https://foo"; embeddingModel = "" }
        $warnings1 = Test-ForgeConfig -Config $config1
        $warnings1 | Should -Match "embeddingEndpoint is set but embeddingModel is empty"

        $config2 = @{ embeddingApiKey = "key"; embeddingEndpoint = "" }
        $warnings2 = Test-ForgeConfig -Config $config2
        $warnings2 | Should -Match "embeddingApiKey is set but embeddingEndpoint is empty"
    }

    It 'Returns warning when builder deployment is missing' {
        $env:BUILDER_DEPLOYMENT = ""
        $config = @{ builderDeployment = "" }
        $warnings = Test-ForgeConfig -Config $config
        $warnings | Should -Match "No builder deployment configured"
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
