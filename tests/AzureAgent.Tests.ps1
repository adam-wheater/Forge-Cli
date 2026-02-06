BeforeAll {
    . "$PSScriptRoot/../lib/AzureAgent.ps1"
    . "$PSScriptRoot/../lib/TokenBudget.ps1"
}

Describe 'Invoke-AzureAgent' {
    Context 'With valid parameters' {
        It 'Returns a string response and updates token usage' {
            $Global:PromptTokens = 0
            $Global:CompletionTokens = 0
            $env:AZURE_OPENAI_ENDPOINT = 'https://example.com'
            $env:AZURE_OPENAI_API_KEY = 'dummy'
            $env:AZURE_OPENAI_API_VERSION = '2023-05-15'
            
            # Mock Invoke-RestMethod
            Mock -CommandName Invoke-RestMethod -MockWith {
                @{ usage = @{ prompt_tokens = 10; completion_tokens = 20 }; choices = @(@{ message = @{ content = 'Test response' } }) }
            }
            
            $result = Invoke-AzureAgent -Deployment 'test' -SystemPrompt 'sys' -UserPrompt 'user' -MaxTokens 100
            $result | Should -Be 'Test response'
            $Global:PromptTokens | Should -Be 10
            $Global:CompletionTokens | Should -Be 20
        }
    }
    Context 'When API returns no usage' {
        It 'Does not throw and returns content' {
            Mock -CommandName Invoke-RestMethod -MockWith {
                @{ choices = @(@{ message = @{ content = 'No usage' } }) }
            }
            $result = Invoke-AzureAgent -Deployment 'test' -SystemPrompt 'sys' -UserPrompt 'user' -MaxTokens 100
            $result | Should -Be 'No usage'
        }
    }
    Context 'When API call fails' {
        It 'Throws an exception' {
            Mock -CommandName Invoke-RestMethod -MockWith { throw 'API error' }
            { Invoke-AzureAgent -Deployment 'test' -SystemPrompt 'sys' -UserPrompt 'user' -MaxTokens 100 } | Should -Throw
        }
    }
}
