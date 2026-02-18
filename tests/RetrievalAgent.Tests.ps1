BeforeAll {
    . "$PSScriptRoot/../lib/TokenBudget.ps1"
    . "$PSScriptRoot/../lib/AzureAgent.ps1"

    # Stub functions that RetrievalAgent.ps1 uses
    Mock -CommandName Write-DebugLog -MockWith {} -ErrorAction SilentlyContinue
    Mock -CommandName Search-Files -MockWith { @("File1.cs", "File2.cs") } -ErrorAction SilentlyContinue
    Mock -CommandName Invoke-SemanticSearch -MockWith { @() } -ErrorAction SilentlyContinue
    Mock -CommandName Read-MemoryFile -MockWith { $null } -ErrorAction SilentlyContinue
    Mock -CommandName Get-MemorySummary -MockWith { "REPO_MEMORY: test" } -ErrorAction SilentlyContinue
    Mock -CommandName Get-SuggestedFix -MockWith { $null } -ErrorAction SilentlyContinue
    Mock -CommandName Get-CSharpSymbols -MockWith { "class Foo { }" } -ErrorAction SilentlyContinue
    Mock -CommandName Get-Imports -MockWith { @("System", "System.Linq") } -ErrorAction SilentlyContinue
    Mock -CommandName Get-ConstructorDependencies -MockWith { @("ILogger", "IService") } -ErrorAction SilentlyContinue
    Mock -CommandName Get-CSharpInterface -MockWith { "interface IFoo { }" } -ErrorAction SilentlyContinue

    . "$PSScriptRoot/../lib/RetrievalAgent.ps1"
}

Describe 'Invoke-SemanticRetrieval' {
    It 'Returns empty string when no results' {
        Mock -CommandName Invoke-SemanticSearch -MockWith { @() }
        $result = Invoke-SemanticRetrieval -Query "find something"
        $result | Should -Be ""
    }

    It 'Formats results with file headers and scores' {
        Mock -CommandName Invoke-SemanticSearch -MockWith {
            @(
                [PSCustomObject]@{ File = "src/Foo.cs"; Content = "class Foo { }"; Similarity = 0.95 }
            )
        }
        $result = Invoke-SemanticRetrieval -Query "find Foo"
        $result | Should -Match "RELEVANT_CODE:"
        $result | Should -Match "src/Foo.cs"
        $result | Should -Match "0.95"
    }
}

Describe 'Invoke-FallbackRetrieval' {
    It 'Returns file list based on keyword search' {
        Mock -CommandName Search-Files -MockWith { @("UserService.cs") }
        $result = Invoke-FallbackRetrieval -Query "find the user service implementation"
        $result | Should -Match "RELEVANT_FILES:"
        $result | Should -Match "UserService.cs"
    }

    It 'Returns empty string when no files match' {
        Mock -CommandName Search-Files -MockWith { @() }
        $result = Invoke-FallbackRetrieval -Query "xyz"
        $result | Should -BeIn @("", "RELEVANT_FILES:")
    }
}

Describe 'Invoke-MemoryRetrieval' {
    It 'Always includes budget information' {
        $result = Invoke-MemoryRetrieval -Level "low"
        $result | Should -Match "BUDGET_REMAINING:"
        $result | Should -Match "Tokens:"
    }

    It 'Returns minimal context for low level' {
        $result = Invoke-MemoryRetrieval -Level "low"
        $result | Should -Match "BUDGET_REMAINING:"
    }

    It 'Returns full summary for high level' {
        $result = Invoke-MemoryRetrieval -Level "high"
        $result | Should -Match "REPO_MEMORY: test"
    }
}

Describe 'Get-FilesFromContext' {
    It 'Returns focus files' {
        $files = Get-FilesFromContext -FocusFiles @("a.cs", "b.cs")
        $files | Should -Contain "a.cs"
        $files | Should -Contain "b.cs"
    }

    It 'Extracts file paths from semantic context' {
        $ctx = "--- src/Foo.cs (score: 0.9) ---`nclass Foo`n--- src/Bar.cs (score: 0.8) ---`nclass Bar"
        $files = Get-FilesFromContext -SemanticContext $ctx
        $files | Should -Contain "src/Foo.cs"
        $files | Should -Contain "src/Bar.cs"
    }

    It 'Returns unique files only' {
        $files = Get-FilesFromContext -FocusFiles @("a.cs", "a.cs")
        ($files | Where-Object { $_ -eq "a.cs" }).Count | Should -Be 1
    }
}

Describe 'Get-PriorTaskResults' {
    BeforeEach {
        $Global:CompletedTasks = @()
    }

    It 'Returns empty when no completed tasks' {
        $task = @{ id = "t2"; dependencies = @("t1") }
        $result = Get-PriorTaskResults -CurrentTask $task
        $result | Should -Be ""
    }

    It 'Returns results from dependency tasks' {
        $Global:CompletedTasks = @(
            @{ id = "t1"; type = "investigate"; instruction = "Find bugs"; result = "Found 3 bugs" }
        )
        $task = @{ id = "t2"; dependencies = @("t1") }
        $result = Get-PriorTaskResults -CurrentTask $task
        $result | Should -Match "PRIOR_RESULTS:"
        $result | Should -Match "Found 3 bugs"
    }

    It 'Ignores non-dependency completed tasks' {
        $Global:CompletedTasks = @(
            @{ id = "t1"; type = "investigate"; instruction = "Unrelated"; result = "Not needed" }
        )
        $task = @{ id = "t2"; dependencies = @("t3") }
        $result = Get-PriorTaskResults -CurrentTask $task
        $result | Should -Be ""
    }
}

Describe 'Build-TaskContext' {
    It 'Always includes task instruction' {
        $task = @{ instruction = "Do something important" }
        $result = Build-TaskContext -Task $task
        $result | Should -Match "TASK_INSTRUCTION:"
        $result | Should -Match "Do something important"
    }

    It 'Includes all context sections when provided' {
        $task = @{ instruction = "Fix bugs" }
        $result = Build-TaskContext -Task $task `
            -SemanticContext "RELEVANT_CODE: ..." `
            -MemoryContext "REPO_MEMORY: ..." `
            -StructuralContext "CODE_STRUCTURE: ..." `
            -PriorResults "PRIOR_RESULTS: ..."
        $result | Should -Match "RELEVANT_CODE"
        $result | Should -Match "REPO_MEMORY"
        $result | Should -Match "CODE_STRUCTURE"
        $result | Should -Match "PRIOR_RESULTS"
    }

    It 'Trims context to token budget' {
        $task = @{ instruction = "Fix" }
        $longContext = "x" * 50000
        $result = Build-TaskContext -Task $task -SemanticContext $longContext -MaxTokens 1000
        $result.Length | Should -BeLessOrEqual 4100  # 1000 * 4 + trimming message
        $result | Should -Match "context trimmed"
    }
}
