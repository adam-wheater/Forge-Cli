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
            { Run-Agent -Role 'builder' -Deployment 'test' -SystemPrompt 'sys' -InitialContext 'init' } | Should -Throw
        }
    }
}
