. "$PSScriptRoot/TokenBudget.ps1"

function Invoke-AzureAgent {
    param (
        [Parameter(Mandatory)][string]$Deployment,
        [Parameter(Mandatory)][string]$SystemPrompt,
        [Parameter(Mandatory)][string]$UserPrompt,
        [int]$MaxTokens = 2048
    )

    $apiVer = $env:AZURE_OPENAI_API_VERSION
    $headers = @{
        'Content-Type'  = 'application/json'
        'Authorization' = "Bearer $($env:AZURE_OPENAI_API_KEY)"
    }

    $bodyVariants = $null
        if ($apiVer -and $apiVer -like '2025*') {
            if ($env:AZURE_OPENAI_ENDPOINT -and $env:AZURE_OPENAI_ENDPOINT -match '/openai/responses') {
                $uri = $env:AZURE_OPENAI_ENDPOINT
                if ($uri -notmatch '\?') { $uri = "$uri?api-version=$apiVer" }
                $bodyObj = @{
                    model = $Deployment
                    input = @(
                        @{ role = 'system'; content = $SystemPrompt },
                        @{ role = 'user'; content = $UserPrompt }
                    )
                    temperature = 0.1
                    max_output_tokens = $MaxTokens
                }
            } else {
                $uri = "$($env:AZURE_OPENAI_ENDPOINT)/openai/deployments/$Deployment/responses?api-version=$apiVer"
                $bodyObj = @{
                    deployment = $Deployment
                    input = @(
                        @{ role = 'system'; content = $SystemPrompt },
                        @{ role = 'user'; content = $UserPrompt }
                    )
                    temperature = 0.1
                    max_output_tokens = $MaxTokens
                }
            }
        } else {
            $uri = "$($env:AZURE_OPENAI_ENDPOINT)/openai/deployments/$Deployment/chat/completions?api-version=$apiVer"
            $bodyObj = @{
                messages = @(
                    @{ role = "system"; content = $SystemPrompt },
                    @{ role = "user"; content = $UserPrompt }
                )
                temperature = 0.1
                max_tokens  = $MaxTokens
            }
        }

        # Convert selected body object to JSON string for request
        try {
            $body = $bodyObj | ConvertTo-Json -Depth 12
        } catch {
            $body = (ConvertTo-Json $bodyObj -Depth 12)
        }

    $maxRetries = 3
    $response = $null
    $triedAlt = $false
    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            Write-Host "Calling Azure OpenAI URI: $uri"
            $response = Invoke-RestMethod -Method POST -Uri $uri -Headers $headers -Body $body
            break
        } catch {
            $errMsg = $_.Exception.Message
            $respBody = $null
            try {
                if ($_.Exception.Response) {
                    $respStream = $_.Exception.Response.GetResponseStream()
                    $reader = New-Object System.IO.StreamReader($respStream)
                    $respBody = $reader.ReadToEnd()
                    $reader.Close()
                    $errMsg = "$errMsg -- ResponseBody: $respBody"
                    Write-Host "Azure error body: $respBody"
                }
            } catch {}

            try {
                if ($_.Exception.Response -and ($_.Exception.Response.StatusCode -eq 400 -or $respBody -match 'Bad Request') -and -not $triedAlt -and ($bodyVariants -ne $null)) {
                    Write-Warning 'Responses API returned 400; retrying with alternate request body variant'
                    $triedAlt = $true
                    $body = $bodyVariants[1] | ConvertTo-Json -Depth 12
                    Start-Sleep -Seconds 1
                    continue
                }
            } catch {}

            if ($attempt -eq $maxRetries) {
                throw "Azure OpenAI API call failed after $maxRetries attempts: $errMsg"
            }
            $backoffSeconds = [Math]::Pow(2, $attempt)
            Write-Warning "API call attempt $attempt failed, retrying in ${backoffSeconds}s: $errMsg"
            Start-Sleep -Seconds $backoffSeconds
        }
    }

    if (-not $response) {
        throw 'Azure OpenAI API returned no response'
    }

    # Persist raw response for debugging
    try {
        $logDir = Join-Path (Get-Location).Path 'tmp-logs'
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $ts = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
        $rawPath = Join-Path $logDir "azure-raw-$ts.json"
        $response | ConvertTo-Json -Depth 20 | Out-File -FilePath $rawPath -Encoding utf8 -Force
    } catch {}

    if ($response.usage) {
        Add-TokenUsage `
            -Prompt $response.usage.prompt_tokens `
            -Completion $response.usage.completion_tokens
    }

    try {
        if ($response.output -and $response.output.Count -gt 0) {
            $pieces = @()
            foreach ($seg in $response.output) {
                # Responses API may contain 'message' objects or content arrays
                if ($seg.type -and $seg.type -eq 'message' -and $seg.content) {
                    foreach ($c in $seg.content) {
                        if ($c.type -and $c.type -eq 'output_text' -and $c.text) { $pieces += $c.text }
                        elseif ($c.text) { $pieces += $c.text }
                    }
                } elseif ($seg.content) {
                    foreach ($c in $seg.content) {
                        if ($c.text) { $pieces += $c.text }
                    }
                } elseif ($seg.text) {
                    $pieces += $seg.text
                }
            }
            $out = ($pieces -join "`n").Trim()
            if ($out) {
                # Always return cleaned text; strip markdown fences if present
                $clean = $out -replace '(^```[a-zA-Z0-9\-]*\r?\n)|(```\r?\n$)', ''
                return $clean.Trim()
            }
        }
    } catch {}

    if ($response.choices -and $response.choices.Count -gt 0) {
        return $response.choices[0].message.content
    }

    return ($response | ConvertTo-Json -Depth 6)
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

    $apiVer = $env:AZURE_OPENAI_API_VERSION
    if ($apiVer -and $apiVer -like '2025*') {
        if ($env:AZURE_OPENAI_ENDPOINT -and $env:AZURE_OPENAI_ENDPOINT -match '/openai/responses') {
            $uri = $env:AZURE_OPENAI_ENDPOINT
            if ($uri -notmatch '\?') { $uri = "$uri?api-version=$apiVer" }
            $bodyObj = @{
                model = $Deployment
                input = $UserPrompt
                temperature = 0.1
                max_output_tokens = $MaxTokens
            }
        } else {
            $uri = "$($env:AZURE_OPENAI_ENDPOINT)/openai/deployments/$Deployment/responses?api-version=$apiVer"
            $bodyObj = @{
                deployment = $Deployment
                input = $UserPrompt
                temperature = 0.1
                max_output_tokens = $MaxTokens
            }
        }
        # For function calling we include messages in the bodyObj only for compatibility when needed
        $bodyObj.system = $SystemPrompt
    } else {
        $uri = "$($env:AZURE_OPENAI_ENDPOINT)/openai/deployments/$Deployment/chat/completions?api-version=$($env:AZURE_OPENAI_API_VERSION)"
        $bodyObj = @{
            messages = @(
                @{ role = "system"; content = $SystemPrompt },
                @{ role = "user"; content = $UserPrompt }
            )
            temperature = 0.1
            max_tokens  = $MaxTokens
        }
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
    $triedAlt = $false
    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            Write-Host "Calling Azure OpenAI (with tools) URI: $uri"
            $body = $bodyObj | ConvertTo-Json -Depth 20
            $response = Invoke-RestMethod -Method POST -Uri $uri -Headers $headers -Body $body
            break
        } catch {
            $errMsg = $_.Exception.Message
            $respBody = $null
            try {
                if ($_.Exception.Response) {
                    $respStream = $_.Exception.Response.GetResponseStream()
                    $reader = New-Object System.IO.StreamReader($respStream)
                    $respBody = $reader.ReadToEnd()
                    $reader.Close()
                    Write-Host "Azure (with tools) error body: $respBody"
                }
            } catch {}

            # On 400 try alternate body using 'model' + simple input string when endpoint is a raw Responses URL
            try {
                if ($_.Exception.Response -and $_.Exception.Response.StatusCode -eq 400 -and -not $triedAlt -and $env:AZURE_OPENAI_ENDPOINT -and $env:AZURE_OPENAI_ENDPOINT -match '/openai/responses') {
                    Write-Warning 'Responses API (with tools) returned 400; retrying with model-style body variant'
                    $triedAlt = $true
                    $altUri = $env:AZURE_OPENAI_ENDPOINT
                    if ($altUri -notmatch '\?') { $altUri = "$altUri?api-version=$apiVer" }
                    $altBody = @{
                        model = $Deployment
                        input = $UserPrompt
                        temperature = 0.1
                        max_output_tokens = $MaxTokens
                        tools = $Tools
                        tool_choice = 'auto'
                    } | ConvertTo-Json -Depth 20
                    Write-Host "Calling Azure OpenAI (with tools) ALT URI: $altUri"
                    try {
                        $response = Invoke-RestMethod -Method POST -Uri $altUri -Headers $headers -Body $altBody -ErrorAction Stop
                        break
                    } catch {
                        # fall through to retry/backoff
                        try { Write-Host "Alt error body: $($_.Exception.Response.GetResponseStream() | Out-String)" } catch {}
                    }
                }
            } catch {}

            if ($attempt -eq $maxRetries) {
                throw "Azure OpenAI API (with tools) call failed after $maxRetries attempts: $errMsg"
            }
            $backoffSeconds = [Math]::Pow(2, $attempt)
            Write-Warning "API call (with tools) attempt $attempt failed, retrying in ${backoffSeconds}s: $errMsg"
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
