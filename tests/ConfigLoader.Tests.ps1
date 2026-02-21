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
        BeforeEach {
            $script:tempConfigPath = Join-Path ([System.IO.Path]::GetTempPath()) "forge-test-validation.json"
        }

        AfterEach {
            if (Test-Path $script:tempConfigPath) {
                Remove-Item $script:tempConfigPath -Force
            }
        }

        It 'Throws error when maxLoops is invalid (critical)' {
            @{ maxLoops = -1 } | ConvertTo-Json | Out-File $script:tempConfigPath -Encoding utf8
            { Load-ForgeConfig -ConfigPath $script:tempConfigPath } | Should -Throw -ErrorId "RuntimeException"
        }

        It 'Throws error when maxTotalTokens is invalid (critical)' {
            @{ maxTotalTokens = -1 } | ConvertTo-Json | Out-File $script:tempConfigPath -Encoding utf8
            { Load-ForgeConfig -ConfigPath $script:tempConfigPath } | Should -Throw -ErrorId "RuntimeException"
        }

        It 'Throws error when maxCostGBP is invalid (critical)' {
            @{ maxCostGBP = -5.0 } | ConvertTo-Json | Out-File $script:tempConfigPath -Encoding utf8
            { Load-ForgeConfig -ConfigPath $script:tempConfigPath } | Should -Throw -ErrorId "RuntimeException"
        }

        It 'Does not throw error for non-critical warnings' {
            # memoryBackend invalid is a warning but not critical
            @{ memoryBackend = "invalid" } | ConvertTo-Json | Out-File $script:tempConfigPath -Encoding utf8
            { Load-ForgeConfig -ConfigPath $script:tempConfigPath } | Should -Not -Throw
        }
    }
}

Describe 'Test-ForgeConfig' {
    BeforeEach {
        # Set dummy deployments to suppress those specific warnings unless we are testing them
        [System.Environment]::SetEnvironmentVariable("BUILDER_DEPLOYMENT", "dummy")
        [System.Environment]::SetEnvironmentVariable("JUDGE_DEPLOYMENT", "dummy")
        # Clear others to ensure clean state
        [System.Environment]::SetEnvironmentVariable("AZURE_OPENAI_ENDPOINT", $null)
    }

    AfterEach {
        [System.Environment]::SetEnvironmentVariable("BUILDER_DEPLOYMENT", $null)
        [System.Environment]::SetEnvironmentVariable("JUDGE_DEPLOYMENT", $null)
        [System.Environment]::SetEnvironmentVariable("AZURE_OPENAI_ENDPOINT", $null)
    }

    It 'Returns warning when maxLoops is non-positive' {
        $warnings = Test-ForgeConfig @{ maxLoops = 0 }
        $warnings | Should -Match "maxLoops must be greater than 0"
    }

    It 'Returns warning when maxTotalTokens is non-positive' {
        $warnings = Test-ForgeConfig @{ maxTotalTokens = -100 }
        $warnings | Should -Match "maxTotalTokens must be greater than 0"
    }

    It 'Returns warning when maxCostGBP is non-positive' {
        $warnings = Test-ForgeConfig @{ maxCostGBP = 0.0 }
        $warnings | Should -Match "maxCostGBP must be greater than 0"
    }

    It 'Returns warning when maxIterationTokens exceeds maxTotalTokens' {
        $warnings = Test-ForgeConfig @{
            maxIterationTokens = 1000
            maxTotalTokens = 500
        }
        $warnings | Should -Match "maxIterationTokens .* exceeds maxTotalTokens"
    }

    It 'Returns warning for invalid memoryBackend' {
        $warnings = Test-ForgeConfig @{ memoryBackend = "cosmosdb" }
        $warnings | Should -Match "memoryBackend must be 'local' or 'redis'"
    }

    It 'Returns warning when redisConnectionString is empty for redis backend' {
        $warnings = Test-ForgeConfig @{
            memoryBackend = "redis"
            redisConnectionString = ""
        }
        $warnings | Should -Match "memoryBackend is 'redis' but redisConnectionString is empty"
    }

    It 'Returns warning when AZURE_OPENAI_ENDPOINT does not start with https' {
        [System.Environment]::SetEnvironmentVariable("AZURE_OPENAI_ENDPOINT", "http://insecure")
        $warnings = Test-ForgeConfig @{}
        $warnings | Should -Match "AZURE_OPENAI_ENDPOINT should start with https://"
    }

    It 'Returns warning when embeddingEndpoint does not start with https' {
        $warnings = Test-ForgeConfig @{ embeddingEndpoint = "http://insecure" }
        $warnings | Should -Match "embeddingEndpoint should start with https://"
    }

    It 'Returns warning when embeddingEndpoint is set but embeddingModel is empty' {
        $warnings = Test-ForgeConfig @{
            embeddingEndpoint = "https://valid"
            embeddingModel = ""
        }
        $warnings | Should -Match "embeddingEndpoint is set but embeddingModel is empty"
    }

    It 'Returns warning when embeddingApiKey is set but embeddingEndpoint is empty' {
        $warnings = Test-ForgeConfig @{
            embeddingApiKey = "secret"
            embeddingEndpoint = ""
        }
        $warnings | Should -Match "embeddingApiKey is set but embeddingEndpoint is empty"
    }

    It 'Returns warning when builderDeployment is missing' {
        [System.Environment]::SetEnvironmentVariable("BUILDER_DEPLOYMENT", $null)
        $warnings = Test-ForgeConfig @{ builderDeployment = "" }
        $warnings | Should -Match "No builder deployment configured"
    }

    It 'Returns warning when judgeDeployment is missing' {
        [System.Environment]::SetEnvironmentVariable("JUDGE_DEPLOYMENT", $null)
        $warnings = Test-ForgeConfig @{ judgeDeployment = "" }
        $warnings | Should -Match "No judge deployment configured"
    }
}

AfterAll {
    $Global:ForgeConfig = @{}
    [System.Environment]::SetEnvironmentVariable("FORGE_MAX_LOOPS", $null)
    [System.Environment]::SetEnvironmentVariable("FORGE_MEMORY_BACKEND", $null)
    [System.Environment]::SetEnvironmentVariable("REDIS_CONNECTION_STRING", $null)
    [System.Environment]::SetEnvironmentVariable("FORGE_DEBUG_MODE", $null)
    [System.Environment]::SetEnvironmentVariable("FORGE_MAX_COST_GBP", $null)
}
