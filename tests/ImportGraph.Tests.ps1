Describe "Get-Imports" {
    BeforeAll {
        . "$PSScriptRoot/../lib/ImportGraph.ps1"
    }

    It "Extracts using statements correctly" {
        $testFile = "TestDrive:\test_class.cs"
        @"
using System;
using System.Collections.Generic;
using Microsoft.Extensions.Logging;
using   System.Threading.Tasks  ;

public class MyService {
    public MyService(ILogger logger, IConfiguration config) {}
    public void MyMethod() {}
}
"@ | Out-File $testFile

        $imports = Get-Imports $testFile
        $imports | Should -Be @("System", "System.Collections.Generic", "Microsoft.Extensions.Logging", "System.Threading.Tasks")
    }

    It "Returns empty array for non-existent file" {
        $imports = Get-Imports "non-existent.cs"
        $imports.Count | Should -Be 0
    }
}
