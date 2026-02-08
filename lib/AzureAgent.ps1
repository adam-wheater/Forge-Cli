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

# J03: Streaming API responses via SSE
function Invoke-AzureAgentStream {
    param (
        [Parameter(Mandatory)][string]$Deployment,
        [Parameter(Mandatory)][string]$SystemPrompt,
        [Parameter(Mandatory)][string]$UserPrompt,
        [int]$MaxTokens = 2048
    )

    # Check if streaming is enabled in config
    $streamingEnabled = $true
    if ($Global:ForgeConfig -and $Global:ForgeConfig.PSObject.Properties['streamingEnabled']) {
        $streamingEnabled = $Global:ForgeConfig.streamingEnabled
    }
    if (-not $streamingEnabled) {
        # Fall back to non-streaming
        return Invoke-AzureAgent -Deployment $Deployment -SystemPrompt $SystemPrompt -UserPrompt $UserPrompt -MaxTokens $MaxTokens
    }

    $uri = "$($env:AZURE_OPENAI_ENDPOINT)/openai/deployments/$Deployment/chat/completions?api-version=$($env:AZURE_OPENAI_API_VERSION)"

    $body = @{
        messages = @(
            @{ role = "system"; content = $SystemPrompt },
            @{ role = "user"; content = $UserPrompt }
        )
        temperature = 0.1
        max_tokens  = $MaxTokens
        stream      = $true
    } | ConvertTo-Json -Depth 12

    $headers = @{
        "Content-Type"  = "application/json"
        "Authorization" = "Bearer $($env:AZURE_OPENAI_API_KEY)"
        "Accept"        = "text/event-stream"
    }

    $maxRetries = 3
    $accumulated = ""
    $promptTokens = 0
    $completionTokens = 0

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            # Use HttpWebRequest for streaming support
            $webRequest = [System.Net.HttpWebRequest]::Create($uri)
            $webRequest.Method = "POST"
            $webRequest.ContentType = "application/json"
            foreach ($key in $headers.Keys) {
                if ($key -ne "Content-Type") {
                    $webRequest.Headers.Add($key, $headers[$key])
                }
            }
            $webRequest.Timeout = 120000

            $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
            $webRequest.ContentLength = $bodyBytes.Length
            $requestStream = $webRequest.GetRequestStream()
            $requestStream.Write($bodyBytes, 0, $bodyBytes.Length)
            $requestStream.Close()

            $webResponse = $webRequest.GetResponse()
            $responseStream = $webResponse.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($responseStream)

            $accumulated = ""
            while (-not $reader.EndOfStream) {
                $line = $reader.ReadLine()

                # SSE format: lines starting with "data: "
                if ($line -match '^data:\s*(.+)$') {
                    $data = $matches[1].Trim()

                    if ($data -eq "[DONE]") {
                        break
                    }

                    try {
                        $chunk = $data | ConvertFrom-Json
                        if ($chunk.choices -and $chunk.choices[0].delta -and $chunk.choices[0].delta.content) {
                            $content = $chunk.choices[0].delta.content
                            $accumulated += $content
                            # Write progress to host for real-time visibility
                            Write-Host $content -NoNewline
                        }

                        # Capture usage from final chunk if provided
                        if ($chunk.usage) {
                            $promptTokens = $chunk.usage.prompt_tokens
                            $completionTokens = $chunk.usage.completion_tokens
                        }
                    } catch {
                        # Skip malformed chunks
                    }
                }
            }

            $reader.Close()
            $responseStream.Close()
            $webResponse.Close()
            Write-Host "" # newline after streaming output
            break
        } catch {
            if ($attempt -eq $maxRetries) {
                throw "Azure OpenAI streaming API call failed after $maxRetries attempts: $($_.Exception.Message)"
            }
            $backoffSeconds = [Math]::Pow(2, $attempt)
            Write-Warning "Streaming API call attempt $attempt failed, retrying in ${backoffSeconds}s: $($_.Exception.Message)"
            Start-Sleep -Seconds $backoffSeconds
        }
    }

    # Track token usage (estimate if not provided by streaming response)
    if ($promptTokens -gt 0 -or $completionTokens -gt 0) {
        Add-TokenUsage -Prompt $promptTokens -Completion $completionTokens
    } else {
        # Estimate: ~4 chars per token
        $estimatedPrompt = [math]::Ceiling(($SystemPrompt.Length + $UserPrompt.Length) / 4)
        $estimatedCompletion = [math]::Ceiling($accumulated.Length / 4)
        Add-TokenUsage -Prompt $estimatedPrompt -Completion $estimatedCompletion
    }

    return $accumulated
}

# J11: Azure OpenAI function calling (native tool use)
function Invoke-AzureAgentWithTools {
    param (
        [Parameter(Mandatory)][string]$Deployment,
        [Parameter(Mandatory)][string]$SystemPrompt,
        [Parameter(Mandatory)][string]$UserPrompt,
        [int]$MaxTokens = 2048,
        [array]$Tools = @()
    )

    $uri = "$($env:AZURE_OPENAI_ENDPOINT)/openai/deployments/$Deployment/chat/completions?api-version=$($env:AZURE_OPENAI_API_VERSION)"

    $bodyObj = @{
        messages = @(
            @{ role = "system"; content = $SystemPrompt },
            @{ role = "user"; content = $UserPrompt }
        )
        temperature = 0.1
        max_tokens  = $MaxTokens
    }

    # Add tools parameter if tools are provided
    if ($Tools -and $Tools.Count -gt 0) {
        $bodyObj.tools = $Tools
        $bodyObj.tool_choice = "auto"
    }

    $body = $bodyObj | ConvertTo-Json -Depth 20

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
                throw "Azure OpenAI API (with tools) call failed after $maxRetries attempts: $($_.Exception.Message)"
            }
            $backoffSeconds = [Math]::Pow(2, $attempt)
            Write-Warning "API call (with tools) attempt $attempt failed, retrying in ${backoffSeconds}s: $($_.Exception.Message)"
            Start-Sleep -Seconds $backoffSeconds
        }
    }

    if ($response.usage) {
        Add-TokenUsage `
            -Prompt $response.usage.prompt_tokens `
            -Completion $response.usage.completion_tokens
    }

    if (-not $response.choices -or $response.choices.Count -eq 0) {
        throw "Azure OpenAI (with tools) returned empty choices array"
    }

    $message = $response.choices[0].message

    # Build structured result
    $result = @{
        Content   = if ($message.content) { $message.content } else { "" }
        ToolCalls = @()
    }

    # Extract tool_calls if present
    if ($message.tool_calls) {
        foreach ($tc in $message.tool_calls) {
            $arguments = @{}
            if ($tc.function.arguments) {
                try {
                    $arguments = $tc.function.arguments | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                } catch {
                    # If -AsHashtable not supported, fall back
                    try {
                        $parsed = $tc.function.arguments | ConvertFrom-Json -ErrorAction Stop
                        # Convert PSObject to hashtable
                        $arguments = @{}
                        $parsed.PSObject.Properties | ForEach-Object { $arguments[$_.Name] = $_.Value }
                    } catch {
                        $arguments = @{ _raw = $tc.function.arguments }
                    }
                }
            }

            $result.ToolCalls += @{
                Id        = $tc.id
                Name      = $tc.function.name
                Arguments = $arguments
            }
        }
    }

    return $result
}
