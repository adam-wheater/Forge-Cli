BeforeAll {
    . "$PSScriptRoot/../lib/ConfigLoader.ps1"
    . "$PSScriptRoot/../lib/TokenBudget.ps1"
    . "$PSScriptRoot/../lib/AzureAgent.ps1"
    . "$PSScriptRoot/../lib/RepoMemory.ps1"

    # Stub out modules that TaskOrchestrator dot-sources transitively
    Mock -CommandName Write-DebugLog -MockWith {} -ErrorAction SilentlyContinue
    Mock -CommandName Search-Files -MockWith { @() } -ErrorAction SilentlyContinue
    Mock -CommandName Initialize-RepoMemory -MockWith {} -ErrorAction SilentlyContinue
    Mock -CommandName Get-MemorySummary -MockWith { "REPO_MEMORY: test repo" } -ErrorAction SilentlyContinue
    Mock -CommandName Read-MemoryFile -MockWith { $null } -ErrorAction SilentlyContinue
    Mock -CommandName Get-SuggestedFix -MockWith { $null } -ErrorAction SilentlyContinue
    Mock -CommandName Build-EmbeddingIndex -MockWith {} -ErrorAction SilentlyContinue
    Mock -CommandName Update-EmbeddingIndex -MockWith {} -ErrorAction SilentlyContinue
    Mock -CommandName Invoke-SemanticSearch -MockWith { @() } -ErrorAction SilentlyContinue
    Mock -CommandName Get-CSharpSymbols -MockWith { "" } -ErrorAction SilentlyContinue

    . "$PSScriptRoot/../lib/TaskOrchestrator.ps1"
}

Describe 'New-ForgeTask' {
    It 'Creates a task with all required fields' {
        $task = New-ForgeTask -Id "task-001" -Type "investigate" -Instruction "Find bugs"
        $task.id | Should -Be "task-001"
        $task.type | Should -Be "investigate"
        $task.instruction | Should -Be "Find bugs"
        $task.status | Should -Be "pending"
        $task.dependencies | Should -HaveCount 0
        $task.workerRole | Should -Be "builder"
        $task.retryCount | Should -Be 0
        $task.maxRetries | Should -Be 2
    }

    It 'Accepts custom dependencies and worker role' {
        $task = New-ForgeTask -Id "task-002" -Type "review" -Instruction "Review code" `
            -Dependencies @("task-001") -WorkerRole "reviewer"
        $task.dependencies | Should -Contain "task-001"
        $task.workerRole | Should -Be "reviewer"
    }

    It 'Rejects invalid task type' {
        { New-ForgeTask -Id "task-003" -Type "invalid" -Instruction "Bad type" } | Should -Throw
    }
}

Describe 'Parse-TaskPlan' {
    It 'Parses a valid JSON task plan' {
        $json = '[{"id":"task-001","type":"investigate","instruction":"Find files","dependencies":[],"workerRole":"builder"}]'
        $tasks = Parse-TaskPlan -Response $json
        $tasks | Should -HaveCount 1
        $tasks[0].id | Should -Be "task-001"
        $tasks[0].type | Should -Be "investigate"
    }

    It 'Handles JSON embedded in prose' {
        $response = "Here is the plan:`n[{`"id`":`"task-001`",`"type`":`"analyze`",`"instruction`":`"Check code`",`"dependencies`":[],`"workerRole`":`"builder`"}]`nEnd."
        $tasks = Parse-TaskPlan -Response $response
        $tasks | Should -HaveCount 1
        $tasks[0].type | Should -Be "analyze"
    }

    It 'Returns null for non-JSON response' {
        $tasks = Parse-TaskPlan -Response "This is not JSON at all"
        $tasks | Should -BeNullOrEmpty
    }

    It 'Parses multiple tasks with dependencies' {
        $json = '[{"id":"task-001","type":"investigate","instruction":"Step 1","dependencies":[],"workerRole":"builder"},{"id":"task-002","type":"modify","instruction":"Step 2","dependencies":["task-001"],"workerRole":"builder"}]'
        $tasks = Parse-TaskPlan -Response $json
        $tasks | Should -HaveCount 2
        $tasks[1].dependencies | Should -Contain "task-001"
    }

    It 'Defaults to investigate for unknown task types' {
        $json = '[{"id":"task-001","type":"unknown_type","instruction":"Do something","dependencies":[],"workerRole":"builder"}]'
        $tasks = Parse-TaskPlan -Response $json
        $tasks[0].type | Should -Be "investigate"
    }
}

Describe 'Test-TaskDependencies' {
    It 'Returns true for valid linear dependencies' {
        $tasks = @(
            @{ id = "t1"; dependencies = @() },
            @{ id = "t2"; dependencies = @("t1") },
            @{ id = "t3"; dependencies = @("t2") }
        )
        Test-TaskDependencies -Tasks $tasks | Should -Be $true
    }

    It 'Returns true for tasks with no dependencies' {
        $tasks = @(
            @{ id = "t1"; dependencies = @() },
            @{ id = "t2"; dependencies = @() }
        )
        Test-TaskDependencies -Tasks $tasks | Should -Be $true
    }

    It 'Returns false for circular dependencies' {
        $tasks = @(
            @{ id = "t1"; dependencies = @("t2") },
            @{ id = "t2"; dependencies = @("t1") }
        )
        Test-TaskDependencies -Tasks $tasks | Should -Be $false
    }

    It 'Returns false for self-referencing dependency' {
        $tasks = @(
            @{ id = "t1"; dependencies = @("t1") }
        )
        Test-TaskDependencies -Tasks $tasks | Should -Be $false
    }
}

Describe 'Get-NextTask' {
    BeforeEach {
        $Global:TaskQueue = @()
        $Global:CompletedTasks = @()
    }

    It 'Returns the first task with no dependencies' {
        $Global:TaskQueue = @(
            @{ id = "t1"; status = "pending"; dependencies = @() },
            @{ id = "t2"; status = "pending"; dependencies = @("t1") }
        )
        $next = Get-NextTask
        $next.id | Should -Be "t1"
    }

    It 'Returns task whose dependencies are completed' {
        $Global:CompletedTasks = @(
            @{ id = "t1"; status = "completed" }
        )
        $Global:TaskQueue = @(
            @{ id = "t2"; status = "pending"; dependencies = @("t1") }
        )
        $next = Get-NextTask
        $next.id | Should -Be "t2"
    }

    It 'Returns null when all tasks are blocked' {
        $Global:TaskQueue = @(
            @{ id = "t2"; status = "pending"; dependencies = @("t1") }
        )
        $next = Get-NextTask
        $next | Should -BeNullOrEmpty
    }

    It 'Returns null for empty queue' {
        $next = Get-NextTask
        $next | Should -BeNullOrEmpty
    }

    It 'Skips non-pending tasks' {
        $Global:TaskQueue = @(
            @{ id = "t1"; status = "active"; dependencies = @() },
            @{ id = "t2"; status = "pending"; dependencies = @() }
        )
        $next = Get-NextTask
        $next.id | Should -Be "t2"
    }
}

Describe 'Add-DynamicTask' {
    BeforeEach {
        $Global:TaskQueue = @()
    }

    It 'Adds a task to the queue' {
        $task = New-ForgeTask -Id "dynamic-001" -Type "investigate" -Instruction "Dynamic task"
        Add-DynamicTask -Task $task
        $Global:TaskQueue | Should -HaveCount 1
        $Global:TaskQueue[0].id | Should -Be "dynamic-001"
    }
}

Describe 'Start-TaskOrchestration' {
    It 'Returns dry run result without executing' {
        Mock -CommandName Invoke-AzureAgent -MockWith {
            '[{"id":"task-001","type":"investigate","instruction":"Look around","dependencies":[],"workerRole":"builder"}]'
        }

        $result = Start-TaskOrchestration -Instruction "Test instruction" -DryRun
        $result.dryRun | Should -Be $true
        $result.tasks | Should -HaveCount 1
    }
}
