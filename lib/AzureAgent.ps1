. "$PSScriptRoot/TokenBudget.ps1"

function Invoke-AzureAgent {
    param (
        [Parameter(Mandatory)][string]$Deployment,
        [Parameter(Mandatory)][string]$SystemPrompt,
        [Parameter(Mandatory)][string]$UserPrompt,
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
        "Content-Type"  = "application/json"
        "Authorization" = "Bearer $($env:AZURE_OPENAI_API_KEY)"
    }

    $maxRetries = 3
    $response = $null
    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            $response = Invoke-RestMethod -Method POST -Uri $uri -Headers $headers -Body $body
            break
        } catch {
            if ($attempt -eq $maxRetries) {
                throw "Azure OpenAI API call failed after $maxRetries attempts: $($_.Exception.Message)"
            }
            $backoffSeconds = [Math]::Pow(2, $attempt)
            Write-Warning "API call attempt $attempt failed, retrying in ${backoffSeconds}s: $($_.Exception.Message)"
            Start-Sleep -Seconds $backoffSeconds
        }
    }

    if ($response.usage) {
        Add-TokenUsage `
            -Prompt $response.usage.prompt_tokens `
            -Completion $response.usage.completion_tokens
    }

    if (-not $response.choices -or $response.choices.Count -eq 0) {
        throw "Azure OpenAI returned empty choices array"
    }

    $response.choices[0].message.content
}
