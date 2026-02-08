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
}

AfterAll {
    $Global:ForgeConfig = @{}
    [System.Environment]::SetEnvironmentVariable("FORGE_MAX_LOOPS", $null)
    [System.Environment]::SetEnvironmentVariable("FORGE_MEMORY_BACKEND", $null)
    [System.Environment]::SetEnvironmentVariable("REDIS_CONNECTION_STRING", $null)
    [System.Environment]::SetEnvironmentVariable("FORGE_DEBUG_MODE", $null)
    [System.Environment]::SetEnvironmentVariable("FORGE_MAX_COST_GBP", $null)
}
