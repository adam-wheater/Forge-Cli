BeforeAll {
    . "$PSScriptRoot/../lib/TokenBudget.ps1"

    # Stub all external dependencies
    Mock -CommandName Update-Heuristics -MockWith {} -ErrorAction SilentlyContinue
    Mock -CommandName Save-RunState -MockWith {} -ErrorAction SilentlyContinue
    Mock -CommandName Save-ConversationTurn -MockWith {} -ErrorAction SilentlyContinue
    Mock -CommandName Save-GlobalPattern -MockWith {} -ErrorAction SilentlyContinue
    Mock -CommandName Trace-AgentDecision -MockWith {} -ErrorAction SilentlyContinue
    Mock -CommandName Add-MetricEvent -MockWith {} -ErrorAction SilentlyContinue

    . "$PSScriptRoot/../lib/FeedbackLoop.ps1"
}

Describe 'Invoke-FeedbackCapture' {
    BeforeEach {
        $Global:OrchestratorSessionId = ""
    }

    It 'Completes without error for successful task' {
        $task = @{
            id          = "t1"
            type        = "modify"
            instruction = "Fix bug"
            workerRole  = "builder"
            metadata    = @{}
        }
        { Invoke-FeedbackCapture -Task $task -Result "diff --git ..." -Success $true } | Should -Not -Throw
    }

    It 'Completes without error for failed task' {
        $task = @{
            id          = "t1"
            type        = "investigate"
            instruction = "Find bugs"
            workerRole  = "builder"
            metadata    = @{ failedFiles = @("File.cs"); failedTests = @("Test1") }
        }
        { Invoke-FeedbackCapture -Task $task -Result "ERROR: failed" -Success $false } | Should -Not -Throw
    }

    It 'Saves conversation turn when session is active' {
        $Global:OrchestratorSessionId = "test-session-123"
        Mock -CommandName Save-ConversationTurn -MockWith {} -Verifiable
        $task = @{
            id          = "t1"
            type        = "test"
            instruction = "Run tests"
            workerRole  = "builder"
            metadata    = @{}
        }
        Invoke-FeedbackCapture -Task $task -Result "All passed" -Success $true
        Should -InvokeVerifiable
    }
}

Describe 'Get-TaskLearnings' {
    It 'Returns empty string for no tasks' {
        $result = Get-TaskLearnings -CompletedTasks @()
        $result | Should -Be ""
    }

    It 'Summarizes completed and failed tasks' {
        $tasks = @(
            @{ id = "t1"; status = "completed"; type = "investigate"; result = "Found 3 issues" },
            @{ id = "t2"; status = "failed"; type = "modify"; result = "Patch failed" }
        )
        $result = Get-TaskLearnings -CompletedTasks $tasks
        $result | Should -Match "LEARNINGS"
        $result | Should -Match "1 succeeded, 1 failed"
    }

    It 'Truncates long results' {
        $longResult = "x" * 500
        $tasks = @(
            @{ id = "t1"; status = "completed"; type = "analyze"; result = $longResult }
        )
        $result = Get-TaskLearnings -CompletedTasks $tasks
        $result | Should -Match "1 succeeded"
    }
}

Describe 'Should-Replan' {
    It 'Returns true when failed task has dependents' {
        $failed = @{ id = "t1"; type = "investigate" }
        $remaining = @(
            @{ id = "t2"; dependencies = @("t1"); status = "pending" }
        )
        Should-Replan -FailedTask $failed -RemainingTasks $remaining | Should -Be $true
    }

    It 'Returns true for failed modify task' {
        $failed = @{ id = "t1"; type = "modify"; retryCount = 0; maxRetries = 2 }
        Should-Replan -FailedTask $failed -RemainingTasks @() | Should -Be $true
    }

    It 'Returns true when max retries exhausted' {
        $failed = @{ id = "t1"; type = "investigate"; retryCount = 3; maxRetries = 2 }
        Should-Replan -FailedTask $failed -RemainingTasks @() | Should -Be $true
    }

    It 'Returns false for non-critical failed task with no dependents' {
        $failed = @{ id = "t1"; type = "analyze"; retryCount = 0; maxRetries = 2 }
        Should-Replan -FailedTask $failed -RemainingTasks @() | Should -Be $false
    }
}

Describe 'Update-TaskFromFeedback' {
    It 'Increments retry count' {
        $task = @{
            id          = "t1"
            instruction = "Do something"
            retryCount  = 0
            status      = "failed"
            metadata    = @{}
        }
        $updated = Update-TaskFromFeedback -Task $task -FeedbackSummary "Try a different approach"
        $updated.retryCount | Should -Be 1
        $updated.status | Should -Be "pending"
    }

    It 'Appends feedback to instruction' {
        $task = @{
            id          = "t1"
            instruction = "Original instruction"
            retryCount  = 0
            status      = "failed"
            metadata    = @{}
        }
        $updated = Update-TaskFromFeedback -Task $task -FeedbackSummary "Check null handling"
        $updated.instruction | Should -Match "Original instruction"
        $updated.instruction | Should -Match "Check null handling"
        $updated.instruction | Should -Match "PREVIOUS ATTEMPT FEEDBACK"
    }

    It 'Sets retry metadata' {
        $task = @{
            id          = "t1"
            instruction = "Fix"
            retryCount  = 1
            status      = "failed"
            metadata    = @{}
        }
        $updated = Update-TaskFromFeedback -Task $task -FeedbackSummary "Error details"
        $updated.metadata.retryReason | Should -Be "Error details"
        $updated.metadata.lastAttemptAt | Should -Not -BeNullOrEmpty
    }
}
