. "$PSScriptRoot/TokenBudget.ps1"

# Build auth headers — Azure OpenAI uses 'api-key'; Azure AD/Foundry tokens use 'Bearer'.
# Heuristic: if the key contains dots (JWT format), assume Bearer; otherwise api-key.
function Get-AzureAuthHeaders {
    $apiKey = $env:AZURE_OPENAI_API_KEY
    $headers = @{ 'Content-Type' = 'application/json' }
    if ($apiKey -match '\.[A-Za-z0-9_-]+\.') {
        $headers['Authorization'] = "Bearer $apiKey"
    } else {
        $headers['api-key'] = $apiKey
    }
    return $headers
}

# Extract token usage from a response, handling both Chat Completions and Responses API field names.
function Read-TokenUsage {
    param($Response)
    if (-not $Response.usage) { return }
    $prompt = 0
    $completion = 0
    if ($Response.usage.prompt_tokens) { $prompt = [int]$Response.usage.prompt_tokens }
    if ($Response.usage.input_tokens) { $prompt = [int]$Response.usage.input_tokens }
    if ($Response.usage.completion_tokens) { $completion = [int]$Response.usage.completion_tokens }
    if ($Response.usage.output_tokens) { $completion = [int]$Response.usage.output_tokens }
    if ($prompt -gt 0 -or $completion -gt 0) {
        Add-TokenUsage -Prompt $prompt -Completion $completion
    }
}

# Extract text content from a Responses API output array.
function Read-ResponsesApiText {
    param($Output)
    if (-not $Output -or $Output.Count -eq 0) { return $null }
    $pieces = @()
    foreach ($seg in $Output) {
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
        $clean = $out -replace '(^```[a-zA-Z0-9\-]*\r?\n)|(```\r?\n$)', ''
        return $clean.Trim()
    }
    return $null
}

function Invoke-AzureAgent {
    param (
        [Parameter(Mandatory)][string]$Deployment,
        [Parameter(Mandatory)][string]$SystemPrompt,
        [Parameter(Mandatory)][string]$UserPrompt,
        [int]$MaxTokens = 4096
    )

    $apiVer = $env:AZURE_OPENAI_API_VERSION
    $headers = Get-AzureAuthHeaders

    # Build URI and body based on API version
    # Responses API docs: https://learn.microsoft.com/en-us/azure/ai-foundry/openai/how-to/responses
    $altBodyObj = $null
    if ($apiVer -and $apiVer -like '2025*') {
        if ($env:AZURE_OPENAI_ENDPOINT -and $env:AZURE_OPENAI_ENDPOINT -match '/openai/(v1/)?responses') {
            # Caller supplied the full Responses API URL
            $uri = $env:AZURE_OPENAI_ENDPOINT
        } else {
            # Construct Responses API URL (v1 path per Azure docs)
            $base = $env:AZURE_OPENAI_ENDPOINT.TrimEnd('/')
            $uri = "$base/openai/v1/responses"
        }
        # Responses API uses 'model' + 'instructions' + 'input' (not messages array)
        $bodyObj = @{
            model = $Deployment
            instructions = $SystemPrompt
            input = $UserPrompt
            temperature = 0.1
            max_output_tokens = $MaxTokens
        }
        # Alternate: try with input as message array instead of string
        $altBodyObj = @{
            model = $Deployment
            instructions = $SystemPrompt
            input = @(
                @{ role = 'user'; content = $UserPrompt }
            )
            temperature = 0.1
            max_output_tokens = $MaxTokens
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

            # On 400, try alternate body format if available
            if (-not $triedAlt -and $altBodyObj -and $_.Exception.Response) {
                try {
                    $statusCode = [int]$_.Exception.Response.StatusCode
                } catch { $statusCode = 0 }
                if ($statusCode -eq 400 -or ($respBody -and $respBody -match 'Bad Request')) {
                    Write-Warning 'Responses API returned 400; retrying with alternate body format'
                    $triedAlt = $true
                    try {
                        $body = $altBodyObj | ConvertTo-Json -Depth 12
                    } catch {
                        $body = ConvertTo-Json $altBodyObj -Depth 12
                    }
                    Start-Sleep -Seconds 1
                    continue
                }
            }

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

    Read-TokenUsage $response

    # Try Responses API output_text convenience field first
    if ($response.output_text) {
        $clean = $response.output_text -replace '(^```[a-zA-Z0-9\-]*\r?\n)|(```\r?\n$)', ''
        return $clean.Trim()
    }

    # Try Responses API format (output array)
    $text = Read-ResponsesApiText $response.output
    if ($text) { return $text }

    # Chat Completions format
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
        [int]$MaxTokens = 4096
    )

    $streamingEnabled = $true
    if ($Global:ForgeConfig -and $Global:ForgeConfig.PSObject.Properties['streamingEnabled']) {
        $streamingEnabled = $Global:ForgeConfig.streamingEnabled
    }
    if (-not $streamingEnabled) {
        return Invoke-AzureAgent -Deployment $Deployment -SystemPrompt $SystemPrompt -UserPrompt $UserPrompt -MaxTokens $MaxTokens
    }

    # Responses API (2025*) uses a different SSE format; fall back to non-streaming for safety
    $apiVer = $env:AZURE_OPENAI_API_VERSION
    if ($apiVer -and $apiVer -like '2025*') {
        return Invoke-AzureAgent -Deployment $Deployment -SystemPrompt $SystemPrompt -UserPrompt $UserPrompt -MaxTokens $MaxTokens
    }

    $uri = "$($env:AZURE_OPENAI_ENDPOINT)/openai/deployments/$Deployment/chat/completions?api-version=$apiVer"

    $body = @{
        messages = @(
            @{ role = "system"; content = $SystemPrompt },
            @{ role = "user"; content = $UserPrompt }
        )
        temperature = 0.1
        max_tokens  = $MaxTokens
        stream      = $true
    } | ConvertTo-Json -Depth 12

    $headers = Get-AzureAuthHeaders
    $headers["Accept"] = "text/event-stream"

    $maxRetries = 3
    $accumulated = ""
    $promptTokens = 0
    $completionTokens = 0

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
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
                if ($line -match '^data:\s*(.+)$') {
                    $data = $matches[1].Trim()
                    if ($data -eq "[DONE]") { break }
                    try {
                        $chunk = $data | ConvertFrom-Json
                        if ($chunk.choices -and $chunk.choices[0].delta -and $chunk.choices[0].delta.content) {
                            $content = $chunk.choices[0].delta.content
                            $accumulated += $content
                            Write-Host $content -NoNewline
                        }
                        if ($chunk.usage) {
                            $promptTokens = $chunk.usage.prompt_tokens
                            $completionTokens = $chunk.usage.completion_tokens
                        }
                    } catch {}
                }
            }

            $reader.Close()
            $responseStream.Close()
            $webResponse.Close()
            Write-Host ""
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

    if ($promptTokens -gt 0 -or $completionTokens -gt 0) {
        Add-TokenUsage -Prompt $promptTokens -Completion $completionTokens
    } else {
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
        [int]$MaxTokens = 4096,
        [array]$Tools = @()
    )

    $apiVer = $env:AZURE_OPENAI_API_VERSION
    $headers = Get-AzureAuthHeaders

    if ($apiVer -and $apiVer -like '2025*') {
        if ($env:AZURE_OPENAI_ENDPOINT -and $env:AZURE_OPENAI_ENDPOINT -match '/openai/(v1/)?responses') {
            $uri = $env:AZURE_OPENAI_ENDPOINT
        } else {
            $base = $env:AZURE_OPENAI_ENDPOINT.TrimEnd('/')
            $uri = "$base/openai/v1/responses"
        }
        $bodyObj = @{
            model = $Deployment
            instructions = $SystemPrompt
            input = $UserPrompt
            temperature = 0.1
            max_output_tokens = $MaxTokens
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

    if ($Tools -and $Tools.Count -gt 0) {
        $bodyObj.tools = $Tools
        $bodyObj.tool_choice = "auto"
    }

    $maxRetries = 3
    $response = $null
    $triedAlt = $false
    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            $body = $bodyObj | ConvertTo-Json -Depth 20
            Write-Host "Calling Azure OpenAI (with tools) URI: $uri"
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

            # On 400 try with input as message array instead of string
            if (-not $triedAlt -and $apiVer -and $apiVer -like '2025*') {
                try {
                    $statusCode = [int]$_.Exception.Response.StatusCode
                } catch { $statusCode = 0 }
                if ($statusCode -eq 400) {
                    Write-Warning 'Responses API (with tools) returned 400; retrying with array input'
                    $triedAlt = $true
                    $bodyObj.input = @( @{ role = 'user'; content = $UserPrompt } )
                    Start-Sleep -Seconds 1
                    continue
                }
            }

            if ($attempt -eq $maxRetries) {
                throw "Azure OpenAI API (with tools) call failed after $maxRetries attempts: $errMsg"
            }
            $backoffSeconds = [Math]::Pow(2, $attempt)
            Write-Warning "API call (with tools) attempt $attempt failed, retrying in ${backoffSeconds}s: $errMsg"
            Start-Sleep -Seconds $backoffSeconds
        }
    }

    if (-not $response) {
        throw 'Azure OpenAI API (with tools) returned no response'
    }

    Read-TokenUsage $response

    # Build structured result handling both Chat Completions and Responses API formats
    $result = @{
        Content   = ""
        ToolCalls = @()
    }

    # Try Responses API output_text convenience field
    if ($response.output_text) {
        $result.Content = $response.output_text
    }

    # Try Responses API format (output array)
    if ($response.output -and $response.output.Count -gt 0) {
        if (-not $result.Content) {
            $text = Read-ResponsesApiText $response.output
            if ($text) { $result.Content = $text }
        }

        # Extract function_call items from Responses API output
        foreach ($seg in $response.output) {
            if ($seg.type -eq 'function_call' -and $seg.name) {
                $arguments = @{}
                if ($seg.arguments) {
                    try {
                        $arguments = $seg.arguments | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                    } catch {
                        try {
                            $parsed = $seg.arguments | ConvertFrom-Json -ErrorAction Stop
                            $arguments = @{}
                            $parsed.PSObject.Properties | ForEach-Object { $arguments[$_.Name] = $_.Value }
                        } catch {
                            $arguments = @{ _raw = $seg.arguments }
                        }
                    }
                }
                $result.ToolCalls += @{
                    Id        = if ($seg.call_id) { $seg.call_id } else { $seg.id }
                    Name      = $seg.name
                    Arguments = $arguments
                }
            }
        }
        return $result
    }

    # Chat Completions format
    if ($response.choices -and $response.choices.Count -gt 0) {
        $message = $response.choices[0].message
        $result.Content = if ($message.content) { $message.content } else { "" }

        if ($message.tool_calls) {
            foreach ($tc in $message.tool_calls) {
                $arguments = @{}
                if ($tc.function.arguments) {
                    try {
                        $arguments = $tc.function.arguments | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                    } catch {
                        try {
                            $parsed = $tc.function.arguments | ConvertFrom-Json -ErrorAction Stop
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

    # No recognized format
    $result.Content = ($response | ConvertTo-Json -Depth 6)
    return $result
}
