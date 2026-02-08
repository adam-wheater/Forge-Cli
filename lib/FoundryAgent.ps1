. "$PSScriptRoot/TokenBudget.ps1"

$Global:FoundryEndpoint = ""
$Global:FoundryApiKey = ""
$Global:FoundryAgents = @{}

function Initialize-FoundryAgent {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$AgentName,
        [Parameter(Mandatory)][string]$SystemPrompt,
        [Parameter(Mandatory)][array]$Tools,
        [string]$DeploymentName = ""
    )

    $endpoint = if ($env:AZURE_AI_FOUNDRY_ENDPOINT) { $env:AZURE_AI_FOUNDRY_ENDPOINT } else { $env:AZURE_OPENAI_ENDPOINT }
    $apiKey = if ($env:AZURE_AI_FOUNDRY_API_KEY) { $env:AZURE_AI_FOUNDRY_API_KEY } else { $env:AZURE_OPENAI_API_KEY }

    if ([string]::IsNullOrWhiteSpace($endpoint)) {
        throw "No Azure AI Foundry endpoint configured. Set AZURE_AI_FOUNDRY_ENDPOINT or AZURE_OPENAI_ENDPOINT."
    }
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        throw "No Azure AI Foundry API key configured. Set AZURE_AI_FOUNDRY_API_KEY or AZURE_OPENAI_API_KEY."
    }

    $Global:FoundryEndpoint = $endpoint.TrimEnd("/")
    $Global:FoundryApiKey = $apiKey

    $uri = "$($Global:FoundryEndpoint)/agents?api-version=2024-12-01-preview"

    $agentBody = @{
        name         = $AgentName
        instructions = $SystemPrompt
        tools        = $Tools
    }

    if ($DeploymentName) {
        $agentBody["model"] = $DeploymentName
    }

    $bodyJson = $agentBody | ConvertTo-Json -Depth 20

    $headers = @{
        "Content-Type"  = "application/json"
        "Authorization" = "Bearer $($Global:FoundryApiKey)"
    }

    $maxRetries = 3
    $response = $null
    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            $response = Invoke-RestMethod -Method POST -Uri $uri -Headers $headers -Body $bodyJson -ErrorAction Stop
            break
        } catch {
            if ($attempt -eq $maxRetries) {
                throw "Failed to create Foundry agent '$AgentName' after $maxRetries attempts: $($_.Exception.Message)"
            }
            $backoffSeconds = [Math]::Pow(2, $attempt)
            Write-Warning "Create agent attempt $attempt failed, retrying in ${backoffSeconds}s: $($_.Exception.Message)"
            Start-Sleep -Seconds $backoffSeconds
        }
    }

    if (-not $response.id) {
        throw "Foundry agent creation returned no agent ID for '$AgentName'"
    }

    $agentId = $response.id
    $Global:FoundryAgents[$agentId] = @{
        Name         = $AgentName
        Id           = $agentId
        SystemPrompt = $SystemPrompt
        Tools        = $Tools
        CreatedAt    = (Get-Date).ToUniversalTime().ToString("o")
    }

    Write-Host "Foundry agent '$AgentName' created with ID: $agentId"
    return $agentId
}

function New-FoundryConversation {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$AgentId
    )

    if ([string]::IsNullOrWhiteSpace($Global:FoundryEndpoint)) {
        throw "Foundry endpoint not initialized. Call Initialize-FoundryAgent first."
    }

    $uri = "$($Global:FoundryEndpoint)/threads?api-version=2024-12-01-preview"

    $headers = @{
        "Content-Type"  = "application/json"
        "Authorization" = "Bearer $($Global:FoundryApiKey)"
    }

    $maxRetries = 3
    $response = $null
    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            $response = Invoke-RestMethod -Method POST -Uri $uri -Headers $headers -Body "{}" -ErrorAction Stop
            break
        } catch {
            if ($attempt -eq $maxRetries) {
                throw "Failed to create Foundry conversation after $maxRetries attempts: $($_.Exception.Message)"
            }
            $backoffSeconds = [Math]::Pow(2, $attempt)
            Write-Warning "Create conversation attempt $attempt failed, retrying in ${backoffSeconds}s: $($_.Exception.Message)"
            Start-Sleep -Seconds $backoffSeconds
        }
    }

    if (-not $response.id) {
        throw "Foundry thread creation returned no thread ID"
    }

    return $response.id
}

function Invoke-FoundryAgent {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$AgentId,
        [Parameter(Mandatory)][string]$UserMessage,
        [string]$ConversationId = ""
    )

    if ([string]::IsNullOrWhiteSpace($Global:FoundryEndpoint)) {
        throw "Foundry endpoint not initialized. Call Initialize-FoundryAgent first."
    }

    # Create a new conversation if one was not provided
    if ([string]::IsNullOrWhiteSpace($ConversationId)) {
        $ConversationId = New-FoundryConversation -AgentId $AgentId
    }

    $headers = @{
        "Content-Type"  = "application/json"
        "Authorization" = "Bearer $($Global:FoundryApiKey)"
    }

    # Step 1: Add user message to thread
    $messageUri = "$($Global:FoundryEndpoint)/threads/$ConversationId/messages?api-version=2024-12-01-preview"
    $messageBody = @{
        role    = "user"
        content = $UserMessage
    } | ConvertTo-Json -Depth 10

    $maxRetries = 3
    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            Invoke-RestMethod -Method POST -Uri $messageUri -Headers $headers -Body $messageBody -ErrorAction Stop | Out-Null
            break
        } catch {
            if ($attempt -eq $maxRetries) {
                throw "Failed to add message to thread '$ConversationId' after $maxRetries attempts: $($_.Exception.Message)"
            }
            $backoffSeconds = [Math]::Pow(2, $attempt)
            Write-Warning "Add message attempt $attempt failed, retrying in ${backoffSeconds}s: $($_.Exception.Message)"
            Start-Sleep -Seconds $backoffSeconds
        }
    }

    # Step 2: Create a run on the thread
    $runUri = "$($Global:FoundryEndpoint)/threads/$ConversationId/runs?api-version=2024-12-01-preview"
    $runBody = @{
        assistant_id = $AgentId
    } | ConvertTo-Json -Depth 10

    $run = $null
    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            $run = Invoke-RestMethod -Method POST -Uri $runUri -Headers $headers -Body $runBody -ErrorAction Stop
            break
        } catch {
            if ($attempt -eq $maxRetries) {
                throw "Failed to create run on thread '$ConversationId' after $maxRetries attempts: $($_.Exception.Message)"
            }
            $backoffSeconds = [Math]::Pow(2, $attempt)
            Write-Warning "Create run attempt $attempt failed, retrying in ${backoffSeconds}s: $($_.Exception.Message)"
            Start-Sleep -Seconds $backoffSeconds
        }
    }

    if (-not $run.id) {
        throw "Foundry run creation returned no run ID"
    }

    # Step 3: Poll for run completion
    $runStatusUri = "$($Global:FoundryEndpoint)/threads/$ConversationId/runs/$($run.id)?api-version=2024-12-01-preview"
    $maxPollAttempts = 60
    $pollIntervalSeconds = 2
    $runResult = $null

    for ($poll = 1; $poll -le $maxPollAttempts; $poll++) {
        try {
            $runResult = Invoke-RestMethod -Method GET -Uri $runStatusUri -Headers $headers -ErrorAction Stop
        } catch {
            Write-Warning "Poll attempt $poll failed: $($_.Exception.Message)"
            Start-Sleep -Seconds $pollIntervalSeconds
            continue
        }

        $status = $runResult.status

        if ($status -eq "completed") {
            break
        } elseif ($status -eq "failed") {
            $errorMsg = if ($runResult.last_error) { $runResult.last_error.message } else { "Unknown error" }
            throw "Foundry agent run failed: $errorMsg"
        } elseif ($status -eq "cancelled" -or $status -eq "expired") {
            throw "Foundry agent run $status"
        } elseif ($status -eq "requires_action") {
            # Tool calls are pending - return them for the caller to handle
            $toolCalls = @()
            if ($runResult.required_action -and $runResult.required_action.submit_tool_outputs) {
                $toolCalls = $runResult.required_action.submit_tool_outputs.tool_calls
            }
            return @{
                Status         = "requires_action"
                RunId          = $run.id
                ConversationId = $ConversationId
                ToolCalls      = $toolCalls
                Content        = $null
                Usage          = $null
            }
        }

        Start-Sleep -Seconds $pollIntervalSeconds
    }

    if ($runResult.status -ne "completed") {
        throw "Foundry agent run timed out after $($maxPollAttempts * $pollIntervalSeconds) seconds"
    }

    # Track token usage if available
    if ($runResult.usage) {
        try {
            $promptTokens = if ($runResult.usage.prompt_tokens) { [int]$runResult.usage.prompt_tokens } else { 0 }
            $completionTokens = if ($runResult.usage.completion_tokens) { [int]$runResult.usage.completion_tokens } else { 0 }
            if ($promptTokens -gt 0 -or $completionTokens -gt 0) {
                Add-TokenUsage -Prompt $promptTokens -Completion $completionTokens
            }
        } catch {
            Write-Warning "Failed to track Foundry agent token usage: $($_.Exception.Message)"
        }
    }

    # Step 4: Retrieve messages from the thread
    $messagesUri = "$($Global:FoundryEndpoint)/threads/$ConversationId/messages?api-version=2024-12-01-preview&order=desc&limit=1"
    $messages = $null
    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            $messages = Invoke-RestMethod -Method GET -Uri $messagesUri -Headers $headers -ErrorAction Stop
            break
        } catch {
            if ($attempt -eq $maxRetries) {
                throw "Failed to retrieve messages from thread '$ConversationId' after $maxRetries attempts: $($_.Exception.Message)"
            }
            $backoffSeconds = [Math]::Pow(2, $attempt)
            Write-Warning "Retrieve messages attempt $attempt failed, retrying in ${backoffSeconds}s: $($_.Exception.Message)"
            Start-Sleep -Seconds $backoffSeconds
        }
    }

    $content = ""
    $toolCalls = @()

    if ($messages.data -and $messages.data.Count -gt 0) {
        $lastMessage = $messages.data[0]
        if ($lastMessage.content) {
            foreach ($block in $lastMessage.content) {
                if ($block.type -eq "text") {
                    $content += $block.text.value
                }
            }
        }
    }

    return @{
        Status         = "completed"
        RunId          = $run.id
        ConversationId = $ConversationId
        ToolCalls      = $toolCalls
        Content        = $content
        Usage          = $runResult.usage
    }
}

function Remove-FoundryAgent {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$AgentId
    )

    if ([string]::IsNullOrWhiteSpace($Global:FoundryEndpoint)) {
        throw "Foundry endpoint not initialized. Call Initialize-FoundryAgent first."
    }

    $uri = "$($Global:FoundryEndpoint)/agents/$AgentId`?api-version=2024-12-01-preview"

    $headers = @{
        "Authorization" = "Bearer $($Global:FoundryApiKey)"
    }

    $maxRetries = 3
    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            Invoke-RestMethod -Method DELETE -Uri $uri -Headers $headers -ErrorAction Stop | Out-Null
            break
        } catch {
            if ($attempt -eq $maxRetries) {
                Write-Warning "Failed to delete Foundry agent '$AgentId' after $maxRetries attempts: $($_.Exception.Message)"
                return
            }
            $backoffSeconds = [Math]::Pow(2, $attempt)
            Write-Warning "Delete agent attempt $attempt failed, retrying in ${backoffSeconds}s: $($_.Exception.Message)"
            Start-Sleep -Seconds $backoffSeconds
        }
    }

    if ($Global:FoundryAgents.ContainsKey($AgentId)) {
        $Global:FoundryAgents.Remove($AgentId)
    }

    Write-Host "Foundry agent '$AgentId' deleted."
}
