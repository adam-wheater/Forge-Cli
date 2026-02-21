BeforeAll {
    . "$PSScriptRoot/../lib/Orchestrator.ps1"
}

Describe 'Invoke-ExplainError' {

    Context 'File Path Extraction' {
        It 'Extracts likely file from error message' {
            $errorText = "Error in src/MyFile.cs: line 10"
            $result = Invoke-ExplainError -ErrorText $errorText
            $result | Should -Match "LikelyFile: src/MyFile.cs"
        }

        It 'Extracts likely file from "at ... in ..." pattern' {
            $errorText = "at Namespace.Class.Method() in /path/to/AnotherFile.cs:line 20"
            $result = Invoke-ExplainError -ErrorText $errorText
            $result | Should -Match "LikelyFile: /path/to/AnotherFile.cs"
        }
    }

    Context 'CS0246 - MissingType' {
        It 'Identifies missing type or namespace' {
            $errorText = "error CS0246: The type or namespace name 'Newtonsoft' could not be found"
            $result = Invoke-ExplainError -ErrorText $errorText
            $result | Should -Match "MissingType:"
            $result | Should -Match "Missing using directive or assembly reference for 'Newtonsoft'"
            $result | Should -Match "install the required NuGet package for 'Newtonsoft'"
        }
    }

    Context 'NullReferenceException' {
        It 'Identifies NullReferenceException' {
            $errorText = "System.NullReferenceException: Object reference not set to an instance of an object."
            $result = Invoke-ExplainError -ErrorText $errorText
            $result | Should -Match "NullReference:"
            $result | Should -Match "Object is null. Check mock setup returns non-null values."
        }
    }

    Context 'InvalidOperationException' {
        It 'Identifies InvalidOperationException' {
            $errorText = "System.InvalidOperationException: Unable to resolve service for type 'IMyService'"
            $result = Invoke-ExplainError -ErrorText $errorText
            $result | Should -Match "InvalidOperation:"
            $result | Should -Match "Check service registration in DI container."
        }
    }

    Context 'NotImplementedException' {
        It 'Identifies NotImplementedException' {
            $errorText = "System.NotImplementedException: The method or operation is not implemented."
            $result = Invoke-ExplainError -ErrorText $errorText
            $result | Should -Match "NotImplemented:"
            $result | Should -Match "Method has throw new NotImplementedException\(\) — needs implementation."
        }
    }

    Context 'CS1002 - SyntaxError (Semicolon)' {
        It 'Identifies missing semicolon' {
            $errorText = "error CS1002: ; expected"
            $result = Invoke-ExplainError -ErrorText $errorText
            $result | Should -Match "SyntaxError:"
            $result | Should -Match "Missing semicolon in C# code"
        }
    }

    Context 'CS1513 - SyntaxError (Brace)' {
        It 'Identifies missing closing brace' {
            $errorText = "error CS1513: } expected"
            $result = Invoke-ExplainError -ErrorText $errorText
            $result | Should -Match "SyntaxError:"
            $result | Should -Match "Expected closing brace '}' in C# code"
        }
    }

    Context 'CS0103 - UndefinedName' {
        It 'Identifies undefined variable or name' {
            $errorText = "error CS0103: The name 'myVar' does not exist in the current context"
            $result = Invoke-ExplainError -ErrorText $errorText
            $result | Should -Match "UndefinedName:"
            $result | Should -Match "The name 'myVar' does not exist"
            $result | Should -Match "Declare the variable 'myVar'"
        }
    }

    Context 'CS0029 - TypeMismatch' {
        It 'Identifies type mismatch' {
            $errorText = "error CS0029: Cannot implicitly convert type 'int' to 'string'"
            $result = Invoke-ExplainError -ErrorText $errorText
            $result | Should -Match "TypeMismatch:"
            $result | Should -Match "Cannot implicitly convert between types"
        }
    }

    Context 'CS0115 - OverrideError' {
        It 'Identifies override error' {
            $errorText = "error CS0115: 'MyClass.MyMethod()': no suitable method found to override"
            $result = Invoke-ExplainError -ErrorText $errorText
            $result | Should -Match "OverrideError:"
            $result | Should -Match "No suitable method found to override"
        }
    }

    Context 'General - Unknown Error' {
        It 'Handles unrecognized errors' {
            $errorText = "Something weird happened"
            $result = Invoke-ExplainError -ErrorText $errorText
            $result | Should -Match "General:"
            $result | Should -Match "Unrecognized error pattern"
        }
    }
}
