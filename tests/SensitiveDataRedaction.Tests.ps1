Describe "Redact-SensitiveData" {
    BeforeAll {
        if (-not (Test-Path env:AZURE_OPENAI_API_KEY)) {
            $env:AZURE_OPENAI_API_KEY = "dummy"
        }
        . "$PSScriptRoot/../lib/AzureAgent.ps1"
    }

    It "Redacts simple JSON with spaces" {
        $input = '{"api-key": "my secret key", "other": "value"}'
        $result = Redact-SensitiveData -InputString $input
        $json = $result | ConvertFrom-Json
        $json.'api-key' | Should -Be "***"
        $json.other | Should -Be "value"
    }

    It "Redacts nested JSON" {
        $input = '{
            "config": {
                "password": "super secret",
                "timeout": 100
            }
        }'
        $result = Redact-SensitiveData -InputString $input
        $json = $result | ConvertFrom-Json
        $json.config.password | Should -Be "***"
        $json.config.timeout | Should -Be 100
    }

    It "Redacts Authorization header" {
         $input = '{"headers": {"Authorization": "Bearer 12345"}}'
         $result = Redact-SensitiveData -InputString $input
         $json = $result | ConvertFrom-Json
         $json.headers.Authorization | Should -Be "***"
    }

    It "Redacts access_token (ends with token)" {
        $input = '{"access_token": "abcdef"}'
        $result = Redact-SensitiveData -InputString $input
        $json = $result | ConvertFrom-Json
        $json.access_token | Should -Be "***"
    }

    It "Redacts generic 'token'" {
        $input = '{"token": "xyz"}'
        $result = Redact-SensitiveData -InputString $input
        $json = $result | ConvertFrom-Json
        $json.token | Should -Be "***"
    }

    It "Does not redact prompt_tokens (ends with tokens)" {
        $input = '{"prompt_tokens": 100}'
        $result = Redact-SensitiveData -InputString $input
        $json = $result | ConvertFrom-Json
        $json.prompt_tokens | Should -Be 100
    }

    It "Falls back to regex for malformed JSON and handles spaces" {
        $input = 'Error: Invalid api-key: "my secret key" at line 1'
        $result = Redact-SensitiveData -InputString $input

        $result | Should -BeOfType [string]
        $result | Should -BeLike '*api-key: "***"*'
        $result | Should -Not -BeLike '*my secret key*'
    }

    It "Falls back to regex for simple key=value" {
        $input = 'Connection string: secret=myvalue; endpoint=...'
        $result = Redact-SensitiveData -InputString $input

        $result | Should -BeLike '*secret=***'
        $result | Should -Not -BeLike '*myvalue*'
    }

    It "Handles null input" {
        $result = Redact-SensitiveData -InputString $null
        $result | Should -BeNullOrEmpty
    }

    It "Handles empty input" {
        $result = Redact-SensitiveData -InputString ""
        $result | Should -Be ""
    }
}
