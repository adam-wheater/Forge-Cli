BeforeAll {
    . "$PSScriptRoot/../lib/Orchestrator.ps1"
}

Describe 'Invoke-ExplainError' {
    $testCases = @(
        @{ ErrorText = "CS0246: The type or namespace name 'Foo' could not be found"; Category = "MissingType"; ExpectedMatch = "MissingType: Missing using directive" }
        @{ ErrorText = "System.NullReferenceException: Object reference not set to an instance of an object."; Category = "NullReference"; ExpectedMatch = "NullReference: Object is null" }
        @{ ErrorText = "System.InvalidOperationException: Operation is not valid due to the current state of the object."; Category = "InvalidOperation"; ExpectedMatch = "InvalidOperation: Check service registration" }
        @{ ErrorText = "System.NotImplementedException: The method or operation is not implemented."; Category = "NotImplemented"; ExpectedMatch = "NotImplemented: Method has throw new NotImplementedException" }
        @{ ErrorText = "CS1002: ; expected"; Category = "SyntaxError"; ExpectedMatch = "SyntaxError: Missing semicolon" }
        @{ ErrorText = "CS1513: } expected"; Category = "SyntaxError"; ExpectedMatch = "SyntaxError: Expected closing brace" }
        @{ ErrorText = "CS0103: The name 'bar' does not exist in the current context"; Category = "UndefinedName"; ExpectedMatch = "UndefinedName: The name 'bar' does not exist" }
        @{ ErrorText = "CS0029: Cannot implicitly convert type 'int' to 'string'"; Category = "TypeMismatch"; ExpectedMatch = "TypeMismatch: Cannot implicitly convert" }
        @{ ErrorText = "CS0115: 'MyClass.MyMethod()': no suitable method found to override"; Category = "OverrideError"; ExpectedMatch = "OverrideError: No suitable method found" }
        @{ ErrorText = "Some unknown error occurred"; Category = "General"; ExpectedMatch = "General: Unrecognized error pattern" }
    )

    It 'Identifies correct category and explanation for <Category>' -TestCases $testCases {
        param($ErrorText, $Category, $ExpectedMatch)

        $result = Invoke-ExplainError -ErrorText $ErrorText
        $result | Should -Match $ExpectedMatch
    }

    Context 'File Path Extraction' {
        It 'Extracts file path from "in <file>" pattern' {
            $errorText = "Error in MyFile.cs line 10"
            $result = Invoke-ExplainError -ErrorText $errorText
            $result | Should -Match "LikelyFile: MyFile.cs"
        }

        It 'Extracts file path from "at <method> in <file>" pattern' {
            $errorText = "at MyClass.MyMethod() in /src/MyFile.cs:line 20"
            $result = Invoke-ExplainError -ErrorText $errorText
            $result | Should -Match "LikelyFile: /src/MyFile.cs"
        }

        It 'Returns empty LikelyFile when no file pattern matches' {
            $errorText = "Just a random error without file info"
            $result = Invoke-ExplainError -ErrorText $errorText
            $result | Should -Match "LikelyFile: \s*$"
        }
    }
}
