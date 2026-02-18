# FeedbackLoop.ps1 — Captures task outcomes and feeds learnings back into the memory system.
# Bridges task completion to memory updates, replanning decisions, and metrics tracking.

function Invoke-FeedbackCapture {
    <#
    .SYNOPSIS
        Records the outcome of a completed task into all relevant memory and tracking systems.
    #>
    param (
        [Parameter(Mandatory)][hashtable]$Task,
        [Parameter(Mandatory)][string]$Result,
        [bool]$Success = $true
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString("o")

    # 1. Update heuristics with task outcome
    try {
        $failedFiles = @()
        $failedTests = @()
        if (-not $Success -and $Task.metadata) {
            if ($Task.metadata.failedFiles) { $failedFiles = $Task.metadata.failedFiles }
            if ($Task.metadata.failedTests) { $failedTests = $Task.metadata.failedTests }
        }

        $fixDesc = if ($Task.type -eq "modify") { $Task.instruction } else { "" }
        Update-Heuristics `
            -FailedFiles $failedFiles `
            -FailedTests $failedTests `
            -FixDescription $fixDesc `
            -FixSucceeded $Success
    } catch {
        Write-Warning "FeedbackLoop: Heuristics update failed: $($_.Exception.Message)"
    }

    # 2. Save run state
    try {
        $recentFiles = @()
        if ($Task.metadata -and $Task.metadata.modifiedFiles) {
            $recentFiles = $Task.metadata.modifiedFiles
        }

        Save-RunState `
            -Iteration ([int]($Task.metadata.stepNumber ?? 0)) `
            -Failures $(if (-not $Success) { @($Result) } else { @() }) `
            -RecentFiles $recentFiles `
            -DiffSummary $(if ($Task.type -eq "modify") { $Result.Substring(0, [math]::Min($Result.Length, 500)) } else { "" }) `
            -BuildOk $Success `
            -TestOk $Success
    } catch {
        Write-Warning "FeedbackLoop: Run state save failed: $($_.Exception.Message)"
    }

    # 3. Save conversation turn (if Redis session active)
    try {
        if ($Global:OrchestratorSessionId) {
            Save-ConversationTurn `
                -SessionId $Global:OrchestratorSessionId `
                -Role $Task.workerRole `
                -Content "Task $($Task.id) ($($Task.type)): $(if ($Success) {'SUCCESS'} else {'FAILED'})`n$($Result.Substring(0, [math]::Min($Result.Length, 1000)))"
        }
    } catch {
        Write-Warning "FeedbackLoop: Conversation save failed: $($_.Exception.Message)"
    }

    # 4. Save as global pattern if it was a successful modification
    try {
        if ($Success -and $Task.type -eq "modify" -and (Get-Command Save-GlobalPattern -ErrorAction SilentlyContinue)) {
            Save-GlobalPattern -Pattern @{
                type        = "fix"
                description = $Task.instruction
                diff        = $Result.Substring(0, [math]::Min($Result.Length, 2000))
                createdAt   = $timestamp
            }
        }
    } catch {
        Write-Warning "FeedbackLoop: Global pattern save failed: $($_.Exception.Message)"
    }

    # 5. Log to decision trace
    try {
        if (Get-Command Trace-AgentDecision -ErrorAction SilentlyContinue) {
            Trace-AgentDecision `
                -Agent "orchestrator" `
                -Action "task_$(if ($Success) {'completed'} else {'failed'})" `
                -Tool $Task.type `
                -Input $Task.instruction `
                -Output $Result.Substring(0, [math]::Min($Result.Length, 500)) `
                -Tokens 0
        }
    } catch {
        Write-Warning "FeedbackLoop: Decision trace failed: $($_.Exception.Message)"
    }

    # 6. Add metric event
    try {
        if (Get-Command Add-MetricEvent -ErrorAction SilentlyContinue) {
            Add-MetricEvent -Event "iteration_end" -Data @{
                taskId    = $Task.id
                taskType  = $Task.type
                success   = $Success
                timestamp = $timestamp
            }
        }
    } catch {
        Write-Warning "FeedbackLoop: Metric event failed: $($_.Exception.Message)"
    }
}

function Get-TaskLearnings {
    <#
    .SYNOPSIS
        Summarizes learnings from completed tasks for the orchestrator's replanning context.
    #>
    param (
        [hashtable[]]$CompletedTasks = @()
    )

    if (-not $CompletedTasks -or $CompletedTasks.Count -eq 0) {
        return ""
    }

    $lines = @("LEARNINGS FROM COMPLETED TASKS:")
    $successes = 0
    $failures = 0

    foreach ($task in $CompletedTasks) {
        $status = if ($task.status -eq "completed") { "OK" } else { "FAILED" }
        if ($task.status -eq "completed") { $successes++ } else { $failures++ }

        $resultSummary = ""
        if ($task.result) {
            # Extract first meaningful line as summary
            $firstLines = ($task.result -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 2) -join " "
            if ($firstLines.Length -gt 200) {
                $firstLines = $firstLines.Substring(0, 200) + "..."
            }
            $resultSummary = $firstLines
        }

        $lines += "  [$status] $($task.id) ($($task.type)): $resultSummary"
    }

    $lines += ""
    $lines += "  Summary: $successes succeeded, $failures failed out of $($CompletedTasks.Count) tasks"

    return ($lines -join "`n")
}

function Should-Replan {
    <#
    .SYNOPSIS
        Determines whether the orchestrator should replan after a task failure.
    .DESCRIPTION
        Returns $true if the failure is critical enough to warrant replanning
        (e.g., the failed task blocks other pending tasks or is a core modification).
    #>
    param (
        [Parameter(Mandatory)][hashtable]$FailedTask,
        [hashtable[]]$RemainingTasks = @()
    )

    # Always replan if the failed task has dependents waiting on it
    foreach ($remaining in $RemainingTasks) {
        if ($remaining.dependencies -and $remaining.dependencies -contains $FailedTask.id) {
            return $true
        }
    }

    # Replan if a modify task failed (core change didn't work)
    if ($FailedTask.type -eq "modify") {
        return $true
    }

    # Replan if max retries exhausted
    if ($FailedTask.retryCount -ge $FailedTask.maxRetries) {
        return $true
    }

    return $false
}

function Update-TaskFromFeedback {
    <#
    .SYNOPSIS
        Modifies a task's instruction and metadata based on feedback from a failed attempt.
    #>
    param (
        [Parameter(Mandatory)][hashtable]$Task,
        [string]$FeedbackSummary = ""
    )

    $Task.retryCount++

    if ($FeedbackSummary) {
        $Task.instruction = "$($Task.instruction)`n`nPREVIOUS ATTEMPT FEEDBACK:`n$FeedbackSummary"
    }

    if (-not $Task.metadata) { $Task.metadata = @{} }
    $Task.metadata.retryReason = $FeedbackSummary
    $Task.metadata.lastAttemptAt = (Get-Date).ToUniversalTime().ToString("o")
    $Task.status = "pending"

    return $Task
}
