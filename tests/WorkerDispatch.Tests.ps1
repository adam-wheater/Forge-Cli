BeforeAll {
    . "$PSScriptRoot/../lib/TokenBudget.ps1"
    . "$PSScriptRoot/../lib/AzureAgent.ps1"

    # Stub dependencies
    Mock -CommandName Write-DebugLog -MockWith {} -ErrorAction SilentlyContinue
    Mock -CommandName Search-Files -MockWith { @() } -ErrorAction SilentlyContinue
    Mock -CommandName Invoke-SemanticSearch -MockWith { @() } -ErrorAction SilentlyContinue
    Mock -CommandName Read-MemoryFile -MockWith { $null } -ErrorAction SilentlyContinue
    Mock -CommandName Get-MemorySummary -MockWith { "" } -ErrorAction SilentlyContinue
    Mock -CommandName Get-SuggestedFix -MockWith { $null } -ErrorAction SilentlyContinue
    Mock -CommandName Get-CSharpSymbols -MockWith { "" } -ErrorAction SilentlyContinue
    Mock -CommandName Get-Imports -MockWith { @() } -ErrorAction SilentlyContinue
    Mock -CommandName Get-ConstructorDependencies -MockWith { @() } -ErrorAction SilentlyContinue

    . "$PSScriptRoot/../lib/WorkerDispatch.ps1"
}

Describe 'Select-AgentPrompt' {
    It 'Returns builder prompt for modify tasks' {
        $prompt = Select-AgentPrompt -TaskType "modify" -WorkerRole "builder"
        $prompt | Should -Not -BeNullOrEmpty
    }

    It 'Returns worker prompt for investigate tasks' {
        $prompt = Select-AgentPrompt -TaskType "investigate" -WorkerRole "builder"
        $prompt | Should -Not -BeNullOrEmpty
    }

    It 'Returns a valid prompt for review tasks' {
        $prompt = Select-AgentPrompt -TaskType "review" -WorkerRole "reviewer"
        $prompt | Should -Not -BeNullOrEmpty
    }

    It 'Falls back to worker prompt for unknown task types' {
        $prompt = Select-AgentPrompt -TaskType "unknown" -WorkerRole "builder"
        $prompt | Should -Not -BeNullOrEmpty
    }
}

Describe 'Select-Deployment' {
    BeforeEach {
        $Global:ForgeConfig = @{}
    }

    It 'Returns env var BUILDER_DEPLOYMENT for builder role' {
        $env:BUILDER_DEPLOYMENT = "test-deployment"
        $result = Select-Deployment -Role "builder"
        $result | Should -Be "test-deployment"
        Remove-Item env:BUILDER_DEPLOYMENT -ErrorAction SilentlyContinue
    }

    It 'Prefers config workerDeployment over env var' {
        $Global:ForgeConfig = @{ workerDeployment = "config-worker" }
        $result = Select-Deployment -Role "builder"
        $result | Should -Be "config-worker"
    }

    It 'Falls back to builder deployment for reviewer' {
        $env:BUILDER_DEPLOYMENT = "fallback-deploy"
        $result = Select-Deployment -Role "reviewer"
        $result | Should -Be "fallback-deploy"
        Remove-Item env:BUILDER_DEPLOYMENT -ErrorAction SilentlyContinue
    }
}

Describe 'Get-WorkerToolPermissions' {
    It 'Returns base permissions when no overrides' {
        $perms = Get-WorkerToolPermissions -Role "builder"
        $perms | Should -Contain "search_files"
        $perms | Should -Contain "open_file"
    }

    It 'Adds tools with + prefix' {
        $perms = Get-WorkerToolPermissions -Role "reviewer" -TaskOverrides @("+write_file")
        $perms | Should -Contain "show_diff"
        $perms | Should -Contain "write_file"
    }

    It 'Removes tools with - prefix' {
        $perms = Get-WorkerToolPermissions -Role "builder" -TaskOverrides @("-write_file")
        $perms | Should -Not -Contain "write_file"
        $perms | Should -Contain "search_files"
    }

    It 'Adds plain tool names if not already present' {
        $perms = Get-WorkerToolPermissions -Role "judge" -TaskOverrides @("search_files")
        $perms | Should -Contain "search_files"
    }

    It 'Returns empty for judge with no overrides' {
        $perms = Get-WorkerToolPermissions -Role "judge"
        $perms | Should -HaveCount 0
    }
}

Describe 'Confirm-WorkerOutput' {
    It 'Accepts valid diff output for diff type' {
        $task = @{ id = "t1" }
        $result = Confirm-WorkerOutput -Result "diff --git a/file.cs b/file.cs`n---" -ExpectedType "diff" -Task $task
        $result | Should -Match "diff --git"
    }

    It 'Accepts NO_CHANGES for any type' {
        $task = @{ id = "t1" }
        $result = Confirm-WorkerOutput -Result "NO_CHANGES" -ExpectedType "diff" -Task $task
        $result | Should -Be "NO_CHANGES"
    }

    It 'Returns error string for hashtable errors' {
        $task = @{ id = "t1" }
        $result = Confirm-WorkerOutput -Result @{ type = "parse_error"; message = "bad response" } -ExpectedType "text" -Task $task
        $result | Should -Match "ERROR:"
    }

    It 'Warns but still returns when output type mismatches' {
        $task = @{ id = "t1" }
        # This should warn but not throw
        $result = Confirm-WorkerOutput -Result "just plain text" -ExpectedType "diff" -Task $task
        $result | Should -Be "just plain text"
    }
}

Describe 'Invoke-ParallelWorkers' {
    It 'Throws when task and context arrays differ in length' {
        $tasks = @(@{ type = "investigate"; workerRole = "builder" })
        $contexts = @("ctx1", "ctx2")
        { Invoke-ParallelWorkers -Tasks $tasks -Contexts $contexts } | Should -Throw
    }
}
