# TaskOrchestrator.ps1 — Central orchestration brain for the Forge agent framework.
# Accepts high-level instructions, decomposes them into subtasks via LLM,
# manages a task queue, and routes subtasks through retrieval -> worker -> feedback.

. "$PSScriptRoot/RetrievalAgent.ps1"
. "$PSScriptRoot/WorkerDispatch.ps1"
. "$PSScriptRoot/FeedbackLoop.ps1"
. "$PSScriptRoot/TokenBudget.ps1"
. "$PSScriptRoot/AzureAgent.ps1"

# Global task state
$Global:TaskQueue = @()
$Global:CompletedTasks = @()
$Global:ActiveTask = $null
$Global:OrchestratorSessionId = ""

function New-ForgeTask {
    <#
    .SYNOPSIS
        Creates a new ForgeTask hashtable with all required fields.
    #>
    param (
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet("investigate", "modify", "test", "review", "analyze")][string]$Type,
        [Parameter(Mandatory)][string]$Instruction,
        [string[]]$Dependencies = @(),
        [string]$WorkerRole = "builder",
        [string[]]$ToolPermissions = @(),
        [int]$MaxRetries = 2
    )

    return @{
        id              = $Id
        type            = $Type
        instruction     = $Instruction
        status          = "pending"
        context         = ""
        result          = ""
        dependencies    = $Dependencies
        workerRole      = $WorkerRole
        toolPermissions = $ToolPermissions
        retryCount      = 0
        maxRetries      = $MaxRetries
        createdAt       = (Get-Date).ToUniversalTime().ToString("o")
        completedAt     = ""
        metadata        = @{}
    }
}

function Start-TaskOrchestration {
    <#
    .SYNOPSIS
        Main entry point: accepts an instruction, decomposes it, and executes the task plan.
    .DESCRIPTION
        1. Builds initial context from repo memory
        2. Calls LLM to decompose instruction into task plan
        3. Executes tasks in dependency order
        4. Captures feedback after each task
        5. Replans on failure if needed
    #>
    param (
        [Parameter(Mandatory)][string]$Instruction,
        [int]$MaxSteps = 20,
        [string]$TaskType = "auto",
        [switch]$DryRun
    )

    # Reset global state
    $Global:TaskQueue = @()
    $Global:CompletedTasks = @()
    $Global:ActiveTask = $null

    Write-Host "`n=== Forge Agent Framework ===" -ForegroundColor Green
    Write-Host "Instruction: $Instruction" -ForegroundColor White
    Write-Host "Max steps: $MaxSteps | Task type: $TaskType" -ForegroundColor Gray
    Write-Host ""

    # 1. Build initial context for the orchestrator
    $initialContext = Build-OrchestratorContext -Instruction $Instruction -TaskType $TaskType

    # 2. Decompose instruction into task plan
    Write-Host "[Orchestrator] Decomposing instruction into task plan..." -ForegroundColor Yellow
    $tasks = Invoke-TaskDecomposition -Instruction $Instruction -Context $initialContext -TaskType $TaskType

    if (-not $tasks -or $tasks.Count -eq 0) {
        Write-Host "[Orchestrator] Failed to decompose instruction. Creating default investigation task." -ForegroundColor Red
        $tasks = @(
            New-ForgeTask -Id "task-001" -Type "investigate" -Instruction "Investigate: $Instruction"
        )
    }

    $Global:TaskQueue = $tasks

    Write-Host "[Orchestrator] Task plan ($($tasks.Count) tasks):" -ForegroundColor Green
    foreach ($t in $tasks) {
        $deps = if ($t.dependencies.Count -gt 0) { " (after: $($t.dependencies -join ', '))" } else { "" }
        Write-Host "  $($t.id) [$($t.type)] $($t.instruction.Substring(0, [math]::Min($t.instruction.Length, 80)))...$deps" -ForegroundColor Gray
    }
    Write-Host ""

    if ($DryRun) {
        Write-Host "[DryRun] Would execute $($tasks.Count) tasks. Stopping." -ForegroundColor Yellow
        return @{
            success = $true
            tasks   = $tasks
            dryRun  = $true
        }
    }

    # 3. Execute task queue
    $stepCount = 0
    $overallSuccess = $true

    while ($true) {
        # Budget check
        try { Enforce-Budgets } catch {
            Write-Host "[Orchestrator] Budget exhausted: $($_.Exception.Message)" -ForegroundColor Red
            break
        }

        # Step limit check
        if ($stepCount -ge $MaxSteps) {
            Write-Host "[Orchestrator] Max steps ($MaxSteps) reached." -ForegroundColor Yellow
            break
        }

        # Get next executable task
        $nextTask = Get-NextTask
        if (-not $nextTask) {
            # Check if there are blocked tasks remaining
            $blocked = $Global:TaskQueue | Where-Object { $_.status -eq "pending" }
            if ($blocked) {
                Write-Host "[Orchestrator] $($blocked.Count) tasks remain blocked. Cannot proceed." -ForegroundColor Yellow
                $overallSuccess = $false
            }
            break
        }

        $stepCount++
        Write-Host "`n--- Step $stepCount/$MaxSteps ---" -ForegroundColor Cyan

        # Execute the task
        $result = Invoke-TaskStep -Task $nextTask
        $taskSuccess = ($nextTask.status -eq "completed")

        # Capture feedback
        Invoke-FeedbackCapture -Task $nextTask -Result ($nextTask.result ?? "") -Success $taskSuccess

        if (-not $taskSuccess) {
            $overallSuccess = $false

            # Check if we should replan
            $remaining = $Global:TaskQueue | Where-Object { $_.status -eq "pending" }
            if (Should-Replan -FailedTask $nextTask -RemainingTasks $remaining) {
                Write-Host "[Orchestrator] Replanning after failure..." -ForegroundColor Yellow
                $newTasks = Invoke-ReplanIfNeeded -FailureContext "Task $($nextTask.id) failed: $($nextTask.result)"
                if ($newTasks) {
                    Write-Host "[Orchestrator] Replan added $($newTasks.Count) new tasks" -ForegroundColor Yellow
                }
            }
        }
    }

    # 4. Compile final result
    $finalResult = @{
        success        = $overallSuccess
        stepsExecuted  = $stepCount
        tasksCompleted = ($Global:CompletedTasks | Where-Object { $_.status -eq "completed" }).Count
        tasksFailed    = ($Global:CompletedTasks | Where-Object { $_.status -eq "failed" }).Count
        tasksRemaining = ($Global:TaskQueue | Where-Object { $_.status -eq "pending" }).Count
        tasks          = $Global:CompletedTasks + ($Global:TaskQueue | Where-Object { $_.status -eq "pending" })
        learnings      = Get-TaskLearnings -CompletedTasks $Global:CompletedTasks
    }

    Write-Host "`n=== Orchestration Complete ===" -ForegroundColor Green
    Write-Host "Steps: $stepCount | Completed: $($finalResult.tasksCompleted) | Failed: $($finalResult.tasksFailed) | Remaining: $($finalResult.tasksRemaining)" -ForegroundColor White

    return $finalResult
}

function Invoke-TaskDecomposition {
    <#
    .SYNOPSIS
        Uses the orchestrator LLM to decompose an instruction into a JSON task plan.
    #>
    param (
        [Parameter(Mandatory)][string]$Instruction,
        [string]$Context = "",
        [string]$TaskType = "auto"
    )

    # Load orchestrator system prompt
    $promptPath = Join-Path $PSScriptRoot ".." "agents" "orchestrator.system.txt"
    if (-not (Test-Path $promptPath)) {
        Write-Warning "TaskOrchestrator: orchestrator.system.txt not found, using default decomposition"
        return @(New-ForgeTask -Id "task-001" -Type "investigate" -Instruction $Instruction)
    }

    $systemPrompt = Get-Content $promptPath -Raw

    # Build the user message
    $userMessage = "INSTRUCTION: $Instruction"
    if ($TaskType -ne "auto") {
        $userMessage += "`nTASK_TYPE_HINT: $TaskType"
    }
    if ($Context) {
        $userMessage += "`n`n$Context"
    }

    # Select deployment for orchestrator
    $deployment = if ($Global:ForgeConfig -and $Global:ForgeConfig.ContainsKey('orchestratorDeployment') -and $Global:ForgeConfig.orchestratorDeployment) {
        $Global:ForgeConfig.orchestratorDeployment
    } elseif ($Global:ForgeConfig -and $Global:ForgeConfig.ContainsKey('builderDeployment') -and $Global:ForgeConfig.builderDeployment) {
        $Global:ForgeConfig.builderDeployment
    } else {
        $env:BUILDER_DEPLOYMENT
    }

    try {
        $response = Invoke-AzureAgent `
            -Deployment $deployment `
            -SystemPrompt $systemPrompt `
            -UserPrompt $userMessage

        return Parse-TaskPlan -Response $response
    } catch {
        Write-Warning "TaskOrchestrator: Decomposition failed: $($_.Exception.Message)"
        return @(New-ForgeTask -Id "task-001" -Type "investigate" -Instruction $Instruction)
    }
}

function Parse-TaskPlan {
    <#
    .SYNOPSIS
        Parses the LLM response into an array of ForgeTask hashtables.
    #>
    param (
        [Parameter(Mandatory)][string]$Response
    )

    # Try to extract JSON array from the response
    $jsonMatch = [regex]::Match($Response, '\[[\s\S]*\]')
    if (-not $jsonMatch.Success) {
        Write-Warning "TaskOrchestrator: No JSON array found in decomposition response"
        return $null
    }

    try {
        $parsed = $jsonMatch.Value | ConvertFrom-Json
    } catch {
        Write-Warning "TaskOrchestrator: Failed to parse task plan JSON: $($_.Exception.Message)"
        return $null
    }

    $tasks = @()
    foreach ($item in $parsed) {
        $taskType = if ($item.type -and $item.type -in @("investigate", "retrieve", "modify", "test", "review", "analyze")) {
            $item.type
        } else {
            "investigate"
        }

        $workerRole = if ($item.workerRole -and $item.workerRole -in @("builder", "reviewer")) {
            $item.workerRole
        } else {
            "builder"
        }

        $deps = @()
        if ($item.dependencies) {
            $deps = @($item.dependencies)
        }

        $task = New-ForgeTask `
            -Id ($item.id ?? "task-$($tasks.Count + 1)") `
            -Type $taskType `
            -Instruction ($item.instruction ?? "No instruction provided") `
            -Dependencies $deps `
            -WorkerRole $workerRole

        $tasks += $task
    }

    # Validate no circular dependencies
    if (-not (Test-TaskDependencies -Tasks $tasks)) {
        Write-Warning "TaskOrchestrator: Circular dependencies detected, clearing all dependencies"
        foreach ($t in $tasks) { $t.dependencies = @() }
    }

    return $tasks
}

function Test-TaskDependencies {
    <#
    .SYNOPSIS
        Validates that the task dependency graph has no cycles (topological sort check).
    #>
    param (
        [Parameter(Mandatory)][hashtable[]]$Tasks
    )

    $visited = @{}
    $inStack = @{}

    function Visit-Task {
        param ([string]$TaskId)

        if ($inStack.ContainsKey($TaskId)) { return $false }  # cycle
        if ($visited.ContainsKey($TaskId)) { return $true }    # already processed

        $inStack[$TaskId] = $true
        $task = $Tasks | Where-Object { $_.id -eq $TaskId }
        if ($task -and $task.dependencies) {
            foreach ($dep in $task.dependencies) {
                if (-not (Visit-Task $dep)) { return $false }
            }
        }

        $inStack.Remove($TaskId)
        $visited[$TaskId] = $true
        return $true
    }

    foreach ($t in $Tasks) {
        if (-not (Visit-Task $t.id)) { return $false }
    }
    return $true
}

function Invoke-TaskStep {
    <#
    .SYNOPSIS
        Executes a single task: retrieves context, dispatches to worker, updates status.
    #>
    param (
        [Parameter(Mandatory)][hashtable]$Task
    )

    $Task.status = "active"
    $Global:ActiveTask = $Task

    Write-Host "[Task $($Task.id)] Starting: $($Task.type) - $($Task.instruction.Substring(0, [math]::Min($Task.instruction.Length, 100)))" -ForegroundColor White

    try {
        # 1. Retrieve context for this task
        $contextBudget = if ($Global:ForgeConfig -and $Global:ForgeConfig.ContainsKey('contextTokenBudget')) {
            [int]$Global:ForgeConfig.contextTokenBudget
        } else {
            8000
        }

        $focusFiles = @()
        if ($Task.metadata -and $Task.metadata.focusFiles) {
            $focusFiles = $Task.metadata.focusFiles
        }

        Write-Host "  [Retrieval] Assembling context..." -ForegroundColor Gray
        $context = Invoke-ContextRetrieval -Task $Task -MaxContextTokens $contextBudget -FocusFiles $focusFiles

        $Task.context = $context

        # 2. Dispatch to worker
        Write-Host "  [Dispatch] Sending to $($Task.workerRole) worker..." -ForegroundColor Gray
        $result = Invoke-WorkerDispatch -Task $Task -Context $context

        # 3. Update task with result
        $Task.result = if ($result -is [string]) { $result } else { "$result" }
        $Task.status = "completed"
        $Task.completedAt = (Get-Date).ToUniversalTime().ToString("o")

        # Check for explicit failure indicators
        if ($Task.result -match '^ERROR:' -or ($Task.result -is [hashtable] -and $Task.result.type -match 'error')) {
            $Task.status = "failed"
        }

        Write-Host "  [Result] Task $($Task.id): $($Task.status)" -ForegroundColor $(if ($Task.status -eq "completed") { "Green" } else { "Red" })

    } catch {
        $Task.status = "failed"
        $Task.result = "EXCEPTION: $($_.Exception.Message)"
        $Task.completedAt = (Get-Date).ToUniversalTime().ToString("o")
        Write-Host "  [Error] Task $($Task.id) failed: $($_.Exception.Message)" -ForegroundColor Red
    }

    # Move from queue to completed
    $Global:CompletedTasks += $Task
    $Global:TaskQueue = @($Global:TaskQueue | Where-Object { $_.id -ne $Task.id })
    $Global:ActiveTask = $null

    return $Task
}

function Get-NextTask {
    <#
    .SYNOPSIS
        Returns the next task from the queue whose dependencies are all satisfied.
    #>
    $completedIds = $Global:CompletedTasks | Where-Object { $_.status -eq "completed" } | ForEach-Object { $_.id }

    foreach ($task in $Global:TaskQueue) {
        if ($task.status -ne "pending") { continue }

        $allDepsMet = $true
        foreach ($dep in $task.dependencies) {
            if ($dep -notin $completedIds) {
                $allDepsMet = $false
                break
            }
        }

        if ($allDepsMet) {
            return $task
        }
    }

    return $null
}

function Add-DynamicTask {
    <#
    .SYNOPSIS
        Injects a new task into the queue during execution.
    #>
    param (
        [Parameter(Mandatory)][hashtable]$Task
    )

    $Global:TaskQueue += $Task
    Write-Host "[Orchestrator] Dynamic task added: $($Task.id) [$($Task.type)]" -ForegroundColor Yellow
}

function Invoke-ReplanIfNeeded {
    <#
    .SYNOPSIS
        Sends failure context back to the orchestrator LLM for plan adjustment.
        Returns new tasks to add to the queue, or $null.
    #>
    param (
        [Parameter(Mandatory)][string]$FailureContext
    )

    $learnings = Get-TaskLearnings -CompletedTasks $Global:CompletedTasks
    $remaining = $Global:TaskQueue | Where-Object { $_.status -eq "pending" }

    $promptPath = Join-Path $PSScriptRoot ".." "agents" "orchestrator.system.txt"
    if (-not (Test-Path $promptPath)) { return $null }

    $systemPrompt = Get-Content $promptPath -Raw

    $replanMessage = @"
A task has failed and I need to adjust the plan.

FAILURE:
$FailureContext

$learnings

REMAINING TASKS:
$($remaining | ForEach-Object { "$($_.id) [$($_.type)] $($_.instruction)" } | Out-String)

Please provide a revised task plan as a JSON array. Include only NEW tasks that should be added.
If no new tasks are needed, return an empty array: []
"@

    $deployment = if ($Global:ForgeConfig -and $Global:ForgeConfig.ContainsKey('orchestratorDeployment') -and $Global:ForgeConfig.orchestratorDeployment) {
        $Global:ForgeConfig.orchestratorDeployment
    } else {
        $env:BUILDER_DEPLOYMENT
    }

    try {
        $response = Invoke-AzureAgent `
            -Deployment $deployment `
            -SystemPrompt $systemPrompt `
            -UserPrompt $replanMessage

        $newTasks = Parse-TaskPlan -Response $response
        if ($newTasks -and $newTasks.Count -gt 0) {
            foreach ($t in $newTasks) {
                Add-DynamicTask -Task $t
            }
            return $newTasks
        }
    } catch {
        Write-Warning "TaskOrchestrator: Replanning failed: $($_.Exception.Message)"
    }

    return $null
}

function Build-OrchestratorContext {
    <#
    .SYNOPSIS
        Builds initial context for the orchestrator LLM's task decomposition.
    #>
    param (
        [Parameter(Mandatory)][string]$Instruction,
        [string]$TaskType = "auto"
    )

    $lines = @()

    # Repo memory summary (brief)
    try {
        $summary = Get-MemorySummary
        if ($summary) {
            # Truncate for orchestrator — it just needs structure overview
            if ($summary.Length -gt 3000) {
                $summary = $summary.Substring(0, 3000) + "`n... (truncated)"
            }
            $lines += $summary
        }
    } catch {
        $lines += "REPO_MEMORY: (unavailable)"
    }

    # Budget info
    $totalTokens = Get-TotalTokens
    $cost = Get-CurrentCostGBP
    $lines += ""
    $lines += "BUDGET_REMAINING:"
    $lines += "  Tokens: $totalTokens / $($Global:MAX_TOTAL_TOKENS)"
    $lines += "  Cost: $([math]::Round($cost, 4)) GBP / $($Global:MAX_COST_GBP) GBP"

    return ($lines -join "`n")
}
