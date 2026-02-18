# WorkerDispatch.ps1 — Dispatches context-enriched tasks to the appropriate worker agent.
# Selects the right prompt, deployment, and tool permissions based on task type,
# then delegates to Run-Agent or Run-AgentWithFunctionCalling from Orchestrator.ps1.

. "$PSScriptRoot/Orchestrator.ps1"

# Worker profile definitions: map task types to agent configurations
$script:WorkerProfiles = @{
    investigate = @{
        Role       = "builder"
        Prompt     = "worker.system.txt"
        OutputType = "text"
    }
    modify = @{
        Role       = "builder"
        Prompt     = "builder.system.txt"
        OutputType = "diff"
    }
    test = @{
        Role       = "builder"
        Prompt     = "worker.system.txt"
        OutputType = "text"
    }
    review = @{
        Role       = "reviewer"
        Prompt     = "reviewer.system.txt"
        OutputType = "verdict"
    }
    analyze = @{
        Role       = "builder"
        Prompt     = "worker.system.txt"
        OutputType = "text"
    }
}

function Invoke-WorkerDispatch {
    <#
    .SYNOPSIS
        Dispatches a single task to the appropriate worker agent with assembled context.
    #>
    param (
        [Parameter(Mandatory)][hashtable]$Task,
        [Parameter(Mandatory)][string]$Context
    )

    $profile = $script:WorkerProfiles[$Task.type]
    if (-not $profile) {
        $profile = $script:WorkerProfiles["investigate"]
        Write-Warning "WorkerDispatch: Unknown task type '$($Task.type)', falling back to investigate profile"
    }

    # Select system prompt
    $systemPrompt = Select-AgentPrompt -TaskType $Task.type -WorkerRole ($Task.workerRole ?? $profile.Role)

    # Select deployment
    $deployment = Select-Deployment -Role ($Task.workerRole ?? $profile.Role)

    # Override role if task specifies one
    $role = if ($Task.workerRole) { $Task.workerRole } else { $profile.Role }

    # Apply any per-task tool permission overrides
    if ($Task.toolPermissions -and $Task.toolPermissions.Count -gt 0) {
        $originalPerms = $TOOL_PERMISSIONS[$role]
        $TOOL_PERMISSIONS[$role] = Get-WorkerToolPermissions -Role $role -TaskOverrides $Task.toolPermissions
    }

    try {
        Write-Host "  [Worker] Dispatching task $($Task.id) ($($Task.type)) to $role agent..." -ForegroundColor Cyan

        # Choose execution mode based on global flag
        $result = if ($USE_FUNCTION_CALLING) {
            Run-AgentWithFunctionCalling `
                -Role $role `
                -Deployment $deployment `
                -SystemPrompt $systemPrompt `
                -InitialContext $Context
        } else {
            Run-Agent `
                -Role $role `
                -Deployment $deployment `
                -SystemPrompt $systemPrompt `
                -InitialContext $Context
        }

        # Validate output against expected type
        $validated = Confirm-WorkerOutput -Result $result -ExpectedType $profile.OutputType -Task $Task

        return $validated
    } finally {
        # Restore original tool permissions if we overrode them
        if ($Task.toolPermissions -and $Task.toolPermissions.Count -gt 0 -and $originalPerms) {
            $TOOL_PERMISSIONS[$role] = $originalPerms
        }
    }
}

function Select-AgentPrompt {
    <#
    .SYNOPSIS
        Maps a task type and worker role to the appropriate system prompt file.
    #>
    param (
        [Parameter(Mandatory)][string]$TaskType,
        [Parameter(Mandatory)][string]$WorkerRole
    )

    $profile = $script:WorkerProfiles[$TaskType]
    $promptFile = if ($profile) { $profile.Prompt } else { "worker.system.txt" }

    $agentsDir = Join-Path $PSScriptRoot ".." "agents"
    $promptPath = Join-Path $agentsDir $promptFile

    if (-not (Test-Path $promptPath)) {
        # Fall back to worker.system.txt
        $promptPath = Join-Path $agentsDir "worker.system.txt"
        if (-not (Test-Path $promptPath)) {
            Write-Warning "WorkerDispatch: No prompt file found for $TaskType/$WorkerRole"
            return "You are a coding assistant. Execute the task described in the context."
        }
    }

    $prompt = Get-Content $promptPath -Raw

    # Append tools documentation if available
    $toolsPath = Join-Path $agentsDir "tools.system.txt"
    if (Test-Path $toolsPath) {
        $prompt += "`n`n" + (Get-Content $toolsPath -Raw)
    }

    return $prompt
}

function Select-Deployment {
    <#
    .SYNOPSIS
        Selects the Azure OpenAI deployment name based on role.
    #>
    param (
        [Parameter(Mandatory)][string]$Role
    )

    $config = $Global:ForgeConfig

    switch ($Role) {
        "builder" {
            if ($config -and $config.ContainsKey('workerDeployment') -and $config.workerDeployment) {
                return $config.workerDeployment
            }
            if ($config -and $config.ContainsKey('builderDeployment') -and $config.builderDeployment) {
                return $config.builderDeployment
            }
            return $env:BUILDER_DEPLOYMENT
        }
        "reviewer" {
            if ($config -and $config.ContainsKey('reviewerDeployment') -and $config.reviewerDeployment) {
                return $config.reviewerDeployment
            }
            return $env:BUILDER_DEPLOYMENT  # fallback to builder deployment
        }
        default {
            if ($config -and $config.ContainsKey('workerDeployment') -and $config.workerDeployment) {
                return $config.workerDeployment
            }
            return $env:BUILDER_DEPLOYMENT
        }
    }
}

function Get-WorkerToolPermissions {
    <#
    .SYNOPSIS
        Builds a tool permission set by merging role defaults with per-task overrides.
    #>
    param (
        [Parameter(Mandatory)][string]$Role,
        [string[]]$TaskOverrides = @()
    )

    $basePermissions = $TOOL_PERMISSIONS[$Role]
    if (-not $basePermissions) { $basePermissions = @() }

    if (-not $TaskOverrides -or $TaskOverrides.Count -eq 0) {
        return $basePermissions
    }

    $merged = @($basePermissions)

    foreach ($override in $TaskOverrides) {
        if ($override.StartsWith("-")) {
            # Remove a tool: "-write_file"
            $toolToRemove = $override.Substring(1)
            $merged = $merged | Where-Object { $_ -ne $toolToRemove }
        } elseif ($override.StartsWith("+")) {
            # Add a tool: "+semantic_search"
            $toolToAdd = $override.Substring(1)
            if ($merged -notcontains $toolToAdd) {
                $merged += $toolToAdd
            }
        } else {
            # Plain name = add if not present
            if ($merged -notcontains $override) {
                $merged += $override
            }
        }
    }

    return $merged
}

function Invoke-ParallelWorkers {
    <#
    .SYNOPSIS
        Dispatches multiple independent tasks in parallel using PowerShell jobs.
    #>
    param (
        [Parameter(Mandatory)][hashtable[]]$Tasks,
        [Parameter(Mandatory)][string[]]$Contexts
    )

    if ($Tasks.Count -ne $Contexts.Count) {
        throw "WorkerDispatch: Task and context arrays must be the same length"
    }

    if ($Tasks.Count -eq 1) {
        # Single task — no parallelism needed
        $result = Invoke-WorkerDispatch -Task $Tasks[0] -Context $Contexts[0]
        return @($result)
    }

    $jobs = @()
    $scriptRoot = $PSScriptRoot

    for ($i = 0; $i -lt $Tasks.Count; $i++) {
        $task = $Tasks[$i]
        $ctx = $Contexts[$i]
        $profile = $script:WorkerProfiles[$task.type]
        $role = if ($task.workerRole) { $task.workerRole } else { $profile.Role }
        $deployment = Select-Deployment -Role $role
        $systemPrompt = Select-AgentPrompt -TaskType $task.type -WorkerRole $role

        $job = Start-Job -ScriptBlock {
            param ($ScriptRoot, $Role, $Deployment, $SystemPrompt, $Context)
            . "$ScriptRoot/Orchestrator.ps1"
            Run-Agent -Role $Role -Deployment $Deployment -SystemPrompt $SystemPrompt -InitialContext $Context
        } -ArgumentList $scriptRoot, $role, $deployment, $systemPrompt, $ctx

        $jobs += @{ Job = $job; TaskIndex = $i }
    }

    # Wait for all jobs with timeout
    $timeout = 600  # 10 minutes
    $results = @($null) * $Tasks.Count

    $allJobs = $jobs | ForEach-Object { $_.Job }
    $completed = $allJobs | Wait-Job -Timeout $timeout

    foreach ($entry in $jobs) {
        $job = $entry.Job
        $idx = $entry.TaskIndex
        if ($job.State -eq "Completed") {
            $results[$idx] = Receive-Job -Job $job
        } else {
            $results[$idx] = "ERROR: Job timed out or failed (state: $($job.State))"
            Stop-Job -Job $job -ErrorAction SilentlyContinue
        }
        Remove-Job -Job $job -ErrorAction SilentlyContinue
    }

    return $results
}

function Confirm-WorkerOutput {
    <#
    .SYNOPSIS
        Validates worker output against expected type. Returns the result as-is
        with a warning if it doesn't match expectations.
    #>
    param (
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$ExpectedType,
        [Parameter(Mandatory)][hashtable]$Task
    )

    # Handle hashtable error results from Run-Agent
    if ($Result -is [hashtable] -and $Result.type) {
        Write-Warning "WorkerDispatch: Task $($Task.id) returned error: $($Result.message)"
        return "ERROR: $($Result.message)"
    }

    $resultStr = if ($Result -is [string]) { $Result } else { "$Result" }

    switch ($ExpectedType) {
        "diff" {
            if ($resultStr -notmatch '(?m)^diff --git' -and $resultStr -ne "NO_CHANGES") {
                Write-Warning "WorkerDispatch: Task $($Task.id) expected a diff but got text output"
            }
        }
        "verdict" {
            if ($resultStr -ne "NO_CHANGES" -and $resultStr -notmatch '(?m)^\{.*"verdict"' -and $resultStr -notmatch '(?m)^diff --git') {
                Write-Warning "WorkerDispatch: Task $($Task.id) expected a verdict but got unexpected output"
            }
        }
        # "text" type accepts anything
    }

    return $resultStr
}
