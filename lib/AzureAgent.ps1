. "$PSScriptRoot/TokenBudget.ps1"

function Invoke-AzureAgent {
    param (
        [string]$Deployment,
        [string]$SystemPrompt,
        [string]$UserPrompt,
        [int]$MaxTokens = 2048
    )

    $uri = "$($env:AZURE_OPENAI_ENDPOINT)/openai/deployments/$Deployment/chat/completions?api-version=$($env:AZURE_OPENAI_API_VERSION)"

    $body = @{
        messages = @(
            @{ role = "system"; content = $SystemPrompt },
            @{ role = "user"; content = $UserPrompt }
        )
        temperature = 0.1
        max_tokens = $MaxTokens
    } | ConvertTo-Json -Depth 12

    $headers = @{
        "Content-Type" = "application/json"
        "api-key"      = $env:AZURE_OPENAI_API_KEY
    }

    $response = Invoke-RestMethod -Method POST -Uri $uri -Headers $headers -Body $body

    if ($response.usage) {
        Add-TokenUsage `
            -Prompt $response.usage.prompt_tokens `
            -Completion $response.usage.completion_tokens
    }

    $response.choices[0].message.content
}
