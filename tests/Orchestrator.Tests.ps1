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

Describe 'Invoke-ExplainError' {
    It 'Extracts LikelyFile from error message' {
        $result = Invoke-ExplainError -ErrorText "Error at MyFile.cs:10"
        $result | Should -Match 'LikelyFile: MyFile.cs'
    }

    It 'Correctly identifies <Category> error' -TestCases @(
        @{ ErrorText = "error CS0246: The type or namespace name 'Foo' could not be found"; Category = "MissingType"; Explanation = "Missing using directive or assembly reference for 'Foo'" }
        @{ ErrorText = "System.NullReferenceException: Object reference not set to an instance of an object."; Category = "NullReference"; Explanation = "Object is null. Check mock setup returns non-null values." }
        @{ ErrorText = "System.InvalidOperationException: Operation is not valid due to the current state of the object."; Category = "InvalidOperation"; Explanation = "Check service registration in DI container." }
        @{ ErrorText = "System.NotImplementedException: The method or operation is not implemented."; Category = "NotImplemented"; Explanation = "Method has throw new NotImplementedException() — needs implementation." }
        @{ ErrorText = "error CS1002: ; expected"; Category = "SyntaxError"; Explanation = "Missing semicolon in C# code" }
        @{ ErrorText = "error CS1513: } expected"; Category = "SyntaxError"; Explanation = "Expected closing brace '}' in C# code" }
        @{ ErrorText = "error CS0103: The name 'bar' does not exist in the current context"; Category = "UndefinedName"; Explanation = "The name 'bar' does not exist in the current context" }
        @{ ErrorText = "error CS0029: Cannot implicitly convert type 'int' to 'string'"; Category = "TypeMismatch"; Explanation = "Cannot implicitly convert between types" }
        @{ ErrorText = "error CS0115: 'MyClass.MyMethod()': no suitable method found to override"; Category = "OverrideError"; Explanation = "No suitable method found to override" }
        @{ ErrorText = "Some random unknown error"; Category = "General"; Explanation = "Unrecognized error pattern" }
    ) {
        param($ErrorText, $Category, $Explanation)
        $result = Invoke-ExplainError -ErrorText $ErrorText
        $result | Should -Match "${Category}: "
        if ($Explanation) {
            $result | Should -Match ([regex]::Escape($Explanation))
        }
    }
}
