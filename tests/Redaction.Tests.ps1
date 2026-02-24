Describe "Redaction Logic" {
    BeforeAll {
        $libDir = Join-Path $PSScriptRoot "../lib"
        $agentScript = Join-Path $libDir "AzureAgent.ps1"
        if (-not (Test-Path $agentScript)) {
            Throw "AzureAgent.ps1 not found at $agentScript"
        }
        . $agentScript
    }

    Context "Redact-SensitiveData" {
        It "Redacts standard api-key in JSON" {
            $c = '{"api-key": "secret123"}'
            $expected = '{"api-key": "***"}'
            $result = Redact-SensitiveData -Content $c
            $result | Should -Be $expected
        }

        It "Redacts Authorization Bearer token" {
            $c = 'Authorization: Bearer my-secret-token-123'
            $expected = 'Authorization: Bearer ***'
            $result = Redact-SensitiveData -Content $c
            $result | Should -Be $expected
        }

        It "Redacts Authorization Basic token" {
            $c = 'Authorization: Basic base64string'
            $expected = 'Authorization: Basic ***'
            $result = Redact-SensitiveData -Content $c
            $result | Should -Be $expected
        }

        It "Redacts refresh_token in JSON" {
            $c = '{"refresh_token": "refresh123"}'
            $expected = '{"refresh_token": "***"}'
            $result = Redact-SensitiveData -Content $c
            $result | Should -Be $expected
        }

        It "Redacts client_secret in JSON" {
            $c = '{"client_secret": "secretABC"}'
            $expected = '{"client_secret": "***"}'
            $result = Redact-SensitiveData -Content $c
            $result | Should -Be $expected
        }

        It "Redacts camelCase clientSecret" {
            $c = '{"clientSecret": "secretXYZ"}'
            $expected = '{"clientSecret": "***"}'
            $result = Redact-SensitiveData -Content $c
            $result | Should -Be $expected
        }

        It "Redacts embedding_api_key (snake_case with hyphen word)" {
            $c = '{"embedding_api_key": "sk-12345"}'
            $expected = '{"embedding_api_key": "***"}'
            $result = Redact-SensitiveData -Content $c
            $result | Should -Be $expected
        }

        It "Redacts connection string Password" {
            $c = 'Server=tcp:myserver.database.windows.net,1433;Initial Catalog=myDb;Persist Security Info=False;User ID=myUser;Password=myPassword;MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;'
            $result = Redact-SensitiveData -Content $c
            ($result -match 'Password=\*\*\*') | Should -Be $true
            ($result -notmatch 'myPassword') | Should -Be $true
        }

        It "Redacts key=value format" {
            $c = 'api_key=secret-value'
            $expected = 'api_key=***'
            $result = Redact-SensitiveData -Content $c
            $result | Should -Be $expected
        }

        It "Redacts mixed content with multiple secrets" {
            $c = "Authorization: Bearer token123 `n {`"api-key`": `"key456`"}"
            $result = Redact-SensitiveData -Content $c
            ($result -match 'Authorization: Bearer \*\*\*') | Should -Be $true
            ($result -match '"api-key": "\*\*\*"') | Should -Be $true
            ($result -notmatch 'token123') | Should -Be $true
            ($result -notmatch 'key456') | Should -Be $true
        }

        It "Redacts auth_token" {
             $c = '{"auth_token": "token789"}'
             $expected = '{"auth_token": "***"}'
             $result = Redact-SensitiveData -Content $c
             $result | Should -Be $expected
        }

        It "Does not redact non-sensitive keys" {
            $c = '{"public_key": "public", "username": "user"}'
            $result = Redact-SensitiveData -Content $c
            $result | Should -Be $c
        }
    }
}
