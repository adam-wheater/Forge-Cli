BeforeAll {
    . "$PSScriptRoot/../lib/Orchestrator.ps1"
    . "$PSScriptRoot/../lib/AzureAgent.ps1"
    . "$PSScriptRoot/../lib/TokenBudget.ps1"
}

Describe 'Run-Agent' {
    BeforeEach {
        Mock -CommandName Write-DebugLog -MockWith {}
        Mock -CommandName Search-Files -MockWith { @('file1.cs', 'file2.cs') }
    }
    Context 'With allowed tool' {
        It 'Processes allowed tool without error' {
            Mock -CommandName Invoke-AzureAgent -MockWith { '{"tool":"search_files","pattern":"Test"}' }
            $result = Run-Agent -Role 'builder' -Deployment 'test' -SystemPrompt 'sys' -InitialContext 'init'
            $result | Should -Be 'NO_CHANGES'
        }
    }
    Context 'With forbidden tool' {
        It 'Throws for forbidden tool' {
            Mock -CommandName Invoke-AzureAgent -MockWith { '{"tool":"forbidden_tool"}' }
            { Run-Agent -Role 'builder' -Deployment 'test' -SystemPrompt 'sys' -InitialContext 'init' } | Should -Throw '*Forbidden tool*'
        }
    }
    Context 'With invalid JSON response' {
        It 'Returns structured error instead of crashing' {
            Mock -CommandName Invoke-AzureAgent -MockWith { 'this is not valid json' }
            $result = Run-Agent -Role 'builder' -Deployment 'test' -SystemPrompt 'sys' -InitialContext 'init'
            $result | Should -BeOfType [hashtable]
            $result.type | Should -Be 'parse_error'
        }
    }
    Context 'With JSON missing tool field' {
        It 'Returns structured error for missing tool' {
            Mock -CommandName Invoke-AzureAgent -MockWith { '{"message":"hello"}' }
            $result = Run-Agent -Role 'builder' -Deployment 'test' -SystemPrompt 'sys' -InitialContext 'init'
            $result | Should -BeOfType [hashtable]
            $result.type | Should -Be 'no_tool'
        }
    }
    Context 'With unknown tool' {
        It 'Throws Forbidden for tool not in permission list' {
            Mock -CommandName Invoke-AzureAgent -MockWith { '{"tool":"unknown_tool_xyz"}' }
            { Run-Agent -Role 'builder' -Deployment 'test' -SystemPrompt 'sys' -InitialContext 'init' } | Should -Throw '*Forbidden tool*'
        }
    }
    Context 'Iteration limit prevents infinite loop' {
        It 'Returns NO_CHANGES after MAX_AGENT_ITERATIONS' {
            $script:MAX_AGENT_ITERATIONS = 3
            $script:callCount = 0
            Mock -CommandName Invoke-AzureAgent -MockWith {
                $script:callCount++
                '{"tool":"search_files","pattern":"Test"}'
            }
            $result = Run-Agent -Role 'builder' -Deployment 'test' -SystemPrompt 'sys' -InitialContext 'init'
            $result | Should -Be 'NO_CHANGES'
        }
    }
    Context 'With diff response' {
        It 'Returns the diff directly' {
            Mock -CommandName Invoke-AzureAgent -MockWith { "diff --git a/file.cs b/file.cs`n--- a/file.cs`n+++ b/file.cs" }
            $result = Run-Agent -Role 'builder' -Deployment 'test' -SystemPrompt 'sys' -InitialContext 'init'
            $result | Should -Match '^diff --git'
        }
    }
    Context 'With NO_CHANGES response' {
        It 'Returns NO_CHANGES' {
            Mock -CommandName Invoke-AzureAgent -MockWith { 'NO_CHANGES' }
            $result = Run-Agent -Role 'builder' -Deployment 'test' -SystemPrompt 'sys' -InitialContext 'init'
            $result | Should -Be 'NO_CHANGES'
        }
    }
    Context 'Parameter validation' {
        It 'Requires Role parameter' {
            Mock -CommandName Invoke-AzureAgent -MockWith { 'NO_CHANGES' }
            { Run-Agent -Deployment 'test' -SystemPrompt 'sys' -InitialContext 'init' } | Should -Throw
        }
    }
}
