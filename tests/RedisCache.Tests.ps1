BeforeAll {
    . "$PSScriptRoot/../lib/ConfigLoader.ps1"
    . "$PSScriptRoot/../lib/RedisCache.ps1"
}

Describe 'Initialize-RedisCache' {
    BeforeEach {
        $Global:RedisHost = ""
        $Global:RedisPort = 6380
        $Global:RedisPassword = ""
        $Global:RedisCacheEnabled = $false
    }

    Context 'With valid connection string' {
        It 'Parses host, port, and password' {
            Initialize-RedisCache -ConnectionString "myredis.redis.cache.windows.net:6380,password=secretKey123,ssl=True,abortConnect=False"
            $Global:RedisHost | Should -Be "myredis.redis.cache.windows.net"
            $Global:RedisPort | Should -Be 6380
            $Global:RedisPassword | Should -Be "secretKey123"
            $Global:RedisCacheEnabled | Should -Be $true
        }
    }

    Context 'With empty connection string' {
        It 'Does not enable cache' {
            Initialize-RedisCache -ConnectionString ""
            $Global:RedisCacheEnabled | Should -Be $false
        }
    }

    Context 'With missing password' {
        It 'Does not enable cache' {
            Initialize-RedisCache -ConnectionString "myredis.redis.cache.windows.net:6380"
            $Global:RedisCacheEnabled | Should -Be $false
        }
    }
}

Describe 'Set-CacheValue and Get-CacheValue' {
    BeforeEach {
        $Global:RedisHost = "test.redis.cache.windows.net"
        $Global:RedisPort = 6380
        $Global:RedisPassword = "testkey"
        $Global:RedisCacheEnabled = $true
    }

    Context 'With mocked REST calls' {
        It 'Set-CacheValue calls Invoke-RestMethod with PUT' {
            Mock -CommandName Invoke-RestMethod -MockWith { $null }

            Set-CacheValue -Key "forge:repo:test" -Value "hello"

            Should -Invoke -CommandName Invoke-RestMethod -Times 1 -ParameterFilter {
                $Method -eq "Put" -and $Uri -like "*cache/forge:repo:test*"
            }
        }

        It 'Get-CacheValue calls Invoke-RestMethod with GET' {
            Mock -CommandName Invoke-RestMethod -MockWith {
                @{ value = "cached-result" }
            }

            $result = Get-CacheValue -Key "forge:repo:test"
            $result | Should -Be "cached-result"
        }
    }

    Context 'When Redis is not enabled' {
        It 'Set-CacheValue does nothing' {
            $Global:RedisCacheEnabled = $false
            Mock -CommandName Invoke-RestMethod -MockWith { throw "Should not be called" }

            { Set-CacheValue -Key "test" -Value "val" } | Should -Not -Throw
            Should -Invoke -CommandName Invoke-RestMethod -Times 0
        }

        It 'Get-CacheValue returns null' {
            $Global:RedisCacheEnabled = $false
            $result = Get-CacheValue -Key "test"
            $result | Should -Be $null
        }
    }
}

Describe 'Remove-CacheValue' {
    BeforeEach {
        $Global:RedisHost = "test.redis.cache.windows.net"
        $Global:RedisPort = 6380
        $Global:RedisPassword = "testkey"
        $Global:RedisCacheEnabled = $true
    }

    It 'Calls Invoke-RestMethod with DELETE' {
        Mock -CommandName Invoke-RestMethod -MockWith { $null }
        Remove-CacheValue -Key "forge:repo:old"
        Should -Invoke -CommandName Invoke-RestMethod -Times 1 -ParameterFilter {
            $Method -eq "Delete"
        }
    }
}

Describe 'Test-RedisConnection' {
    Context 'When Redis is unavailable' {
        It 'Returns false when not enabled' {
            $Global:RedisCacheEnabled = $false
            Test-RedisConnection | Should -Be $false
        }

        It 'Returns false when REST call fails' {
            $Global:RedisCacheEnabled = $true
            $Global:RedisHost = "test.redis.cache.windows.net"
            $Global:RedisPort = 6380
            $Global:RedisPassword = "testkey"

            Mock -CommandName Invoke-RestMethod -MockWith { throw "Connection refused" }
            Test-RedisConnection | Should -Be $false
        }
    }

    Context 'When Redis is available' {
        It 'Returns true when ping succeeds' {
            $Global:RedisCacheEnabled = $true
            $Global:RedisHost = "test.redis.cache.windows.net"
            $Global:RedisPort = 6380
            $Global:RedisPassword = "testkey"

            Mock -CommandName Invoke-RestMethod -MockWith { @{ status = "PONG" } }
            Test-RedisConnection | Should -Be $true
        }
    }
}

Describe 'Redis unavailable graceful fallback' {
    BeforeEach {
        $Global:RedisCacheEnabled = $true
        $Global:RedisHost = "test.redis.cache.windows.net"
        $Global:RedisPort = 6380
        $Global:RedisPassword = "testkey"
    }

    It 'Get-CacheValue returns null on REST failure without throwing' {
        Mock -CommandName Invoke-RestMethod -MockWith { throw "Connection refused" }
        $result = Get-CacheValue -Key "forge:repo:missing"
        $result | Should -Be $null
    }

    It 'Set-CacheValue does not throw on REST failure' {
        Mock -CommandName Invoke-RestMethod -MockWith { throw "Connection refused" }
        { Set-CacheValue -Key "forge:repo:test" -Value "val" } | Should -Not -Throw
    }

    It 'Search-CacheKeys returns empty array on REST failure' {
        Mock -CommandName Invoke-RestMethod -MockWith { throw "Connection refused" }
        $result = Search-CacheKeys -Pattern "forge:*"
        $result | Should -HaveCount 0
    }
}

Describe 'Save-MemoryValue with local backend' {
    BeforeEach {
        $Global:ForgeConfig = @{ memoryBackend = "local" }
        $script:tempMemRoot = Join-Path ([System.IO.Path]::GetTempPath()) "forge-mem-test-$(Get-Random)"
    }

    AfterEach {
        if (Test-Path $script:tempMemRoot) {
            Remove-Item $script:tempMemRoot -Recurse -Force
        }
    }

    It 'Writes a JSON file to MemoryRoot' {
        Save-MemoryValue -Key "test-key" -Value "test-value" -MemoryRoot $script:tempMemRoot

        $filePath = Join-Path $script:tempMemRoot "test-key.json"
        Test-Path $filePath | Should -Be $true

        $content = Get-Content $filePath -Raw | ConvertFrom-Json
        $content.key | Should -Be "test-key"
        $content.value | Should -Be "test-value"
    }

    It 'Creates MemoryRoot directory if it does not exist' {
        Test-Path $script:tempMemRoot | Should -Be $false
        Save-MemoryValue -Key "create-dir" -Value "data" -MemoryRoot $script:tempMemRoot
        Test-Path $script:tempMemRoot | Should -Be $true
    }
}

Describe 'Read-MemoryValue with local backend' {
    BeforeEach {
        $Global:ForgeConfig = @{ memoryBackend = "local" }
        $script:tempMemRoot = Join-Path ([System.IO.Path]::GetTempPath()) "forge-mem-test-$(Get-Random)"
    }

    AfterEach {
        if (Test-Path $script:tempMemRoot) {
            Remove-Item $script:tempMemRoot -Recurse -Force
        }
    }

    It 'Reads value from a JSON file' {
        Save-MemoryValue -Key "read-test" -Value "hello-world" -MemoryRoot $script:tempMemRoot
        $result = Read-MemoryValue -Key "read-test" -MemoryRoot $script:tempMemRoot
        $result | Should -Be "hello-world"
    }

    It 'Returns null when key does not exist' {
        $result = Read-MemoryValue -Key "missing-key" -MemoryRoot $script:tempMemRoot
        $result | Should -Be $null
    }
}

Describe 'Get-MemoryBackend' {
    It 'Returns local when ForgeConfig not set' {
        $Global:ForgeConfig = @{}
        Get-MemoryBackend | Should -Be "local"
    }

    It 'Returns the configured backend' {
        $Global:ForgeConfig = @{ memoryBackend = "redis" }
        Get-MemoryBackend | Should -Be "redis"
    }
}

AfterAll {
    $Global:RedisHost = ""
    $Global:RedisPort = 6380
    $Global:RedisPassword = ""
    $Global:RedisCacheEnabled = $false
    $Global:ForgeConfig = @{}
}
