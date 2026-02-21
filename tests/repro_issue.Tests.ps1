
$global:FORGE_DEBUG = $true
$env:AZURE_OPENAI_ENDPOINT = "https://example.com"
$env:AZURE_OPENAI_API_KEY = "dummy"
$env:AZURE_OPENAI_API_VERSION = "2023-05-15"

Describe 'Invoke-AzureAgent Security' {
    BeforeAll {
        . "$PSScriptRoot/../lib/AzureAgent.ps1"
        # We need to mock TokenBudget functions as they are called
        function Add-TokenUsage { param($Prompt, $Completion) }
    }

    It 'Redacts sensitive data from debug logs' {
        $sensitiveData = "SENSITIVE_PASSWORD_123"

        Mock -CommandName Invoke-RestMethod -MockWith {
            return [PSCustomObject]@{
                id = "chatcmpl-123"
                object = "chat.completion"
                created = 1677652288
                model = "gpt-3.5-turbo-0613"
                choices = @(
                    [PSCustomObject]@{
                        index = 0
                        message = [PSCustomObject]@{
                            role = "assistant"
                            content = "Here is your secret: $sensitiveData"
                        }
                        finish_reason = "stop"
                    }
                )
                usage = [PSCustomObject]@{
                    prompt_tokens = 9
                    completion_tokens = 12
                    total_tokens = 21
                }
            }
        }

        # Clear existing logs
        $logDir = Join-Path (Get-Location).Path 'tmp-logs'
        if (Test-Path $logDir) { Remove-Item -Path $logDir -Recurse -Force -ErrorAction SilentlyContinue }

        # Invoke
        $result = Invoke-AzureAgent -Deployment 'test' -SystemPrompt 'sys' -UserPrompt 'user' -MaxTokens 100

        # Verify log file
        $logFiles = Get-ChildItem -Path $logDir -Filter "azure-raw-*.json"
        $logFiles.Count | Should -Be 1

        $content = Get-Content -Path $logFiles[0].FullName -Raw
        $content | Should -Match "chat.completion"

        # This assertion is expected to FAIL before the fix
        $content | Should -Not -Match $sensitiveData
        $content | Should -Match "REDACTED"
    }
}
