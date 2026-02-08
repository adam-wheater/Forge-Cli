BeforeAll {
    # E45: Pester tests for new agent tools
    # Tests: write_file path validation, run_tests invocation limits,
    # get_coverage Cobertura XML parsing, get_symbols Roslyn output parsing

    . "$PSScriptRoot/../lib/TokenBudget.ps1"
    . "$PSScriptRoot/../lib/RelevanceTracker.ps1"
    . "$PSScriptRoot/../lib/RepoTools.ps1"
    . "$PSScriptRoot/../lib/AzureAgent.ps1"
    . "$PSScriptRoot/../lib/Orchestrator.ps1"
    . "$PSScriptRoot/../lib/CSharpAnalyser.ps1"
}

# --- write_file path validation ---
Describe 'Invoke-WriteFile' {
    BeforeAll {
        $script:repoRoot = Join-Path $TestDrive 'writerepo'
        New-Item -ItemType Directory -Path $script:repoRoot -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:repoRoot 'tests') -Force | Out-Null
    }

    Context 'Rejects paths outside repository root' {
        It 'Returns WRITE_FAILED for directory traversal' {
            $result = Invoke-WriteFile -Path '../../../etc/passwd' -Content 'malicious' -RepoRoot $script:repoRoot
            $result | Should -Match 'WRITE_FAILED'
            $result | Should -Match 'outside the repository root'
        }

        It 'Returns WRITE_FAILED for absolute path outside repo' {
            $result = Invoke-WriteFile -Path '/tmp/outside.cs' -Content 'malicious' -RepoRoot $script:repoRoot
            $result | Should -Match 'WRITE_FAILED'
            $result | Should -Match 'outside the repository root'
        }
    }

    Context 'Rejects non-.cs files' {
        It 'Returns WRITE_FAILED for .ps1 files' {
            $result = Invoke-WriteFile -Path 'tests/helper.ps1' -Content 'content' -RepoRoot $script:repoRoot
            $result | Should -Match 'WRITE_FAILED'
            $result | Should -Match 'Only .cs files'
        }

        It 'Returns WRITE_FAILED for .txt files' {
            $result = Invoke-WriteFile -Path 'notes.txt' -Content 'content' -RepoRoot $script:repoRoot
            $result | Should -Match 'WRITE_FAILED'
            $result | Should -Match 'Only .cs files'
        }

        It 'Returns WRITE_FAILED for .json files' {
            $result = Invoke-WriteFile -Path 'config.json' -Content '{}' -RepoRoot $script:repoRoot
            $result | Should -Match 'WRITE_FAILED'
            $result | Should -Match 'Only .cs files'
        }
    }

    Context 'Accepts valid .cs file paths within repo' {
        It 'Writes a .cs file successfully' {
            $content = "public class MyTest { }"
            $result = Invoke-WriteFile -Path 'tests/MyTest.cs' -Content $content -RepoRoot $script:repoRoot
            $result | Should -Match 'FILE_WRITTEN'

            $writtenPath = Join-Path $script:repoRoot 'tests' 'MyTest.cs'
            Test-Path $writtenPath | Should -BeTrue
        }

        It 'Creates directory structure if needed' {
            $content = "public class DeepTest { }"
            $result = Invoke-WriteFile -Path 'tests/Nested/Deep/DeepTest.cs' -Content $content -RepoRoot $script:repoRoot
            $result | Should -Match 'FILE_WRITTEN'

            $writtenPath = Join-Path $script:repoRoot 'tests' 'Nested' 'Deep' 'DeepTest.cs'
            Test-Path $writtenPath | Should -BeTrue
        }

        It 'Reports line count in result' {
            $content = "line1`nline2`nline3"
            $result = Invoke-WriteFile -Path 'tests/LineCount.cs' -Content $content -RepoRoot $script:repoRoot
            $result | Should -Match 'FILE_WRITTEN'
            $result | Should -Match 'lines'
        }
    }

    Context 'Handles edge cases' {
        It 'Writes empty content' {
            $result = Invoke-WriteFile -Path 'tests/Empty.cs' -Content '' -RepoRoot $script:repoRoot
            $result | Should -Match 'FILE_WRITTEN'
        }

        It 'Overwrites existing file' {
            $path = 'tests/Overwrite.cs'
            Invoke-WriteFile -Path $path -Content 'original' -RepoRoot $script:repoRoot
            $result = Invoke-WriteFile -Path $path -Content 'updated' -RepoRoot $script:repoRoot
            $result | Should -Match 'FILE_WRITTEN'

            $writtenPath = Join-Path $script:repoRoot $path
            $content = Get-Content $writtenPath -Raw
            $content | Should -Match 'updated'
        }
    }
}

# --- run_tests invocation limits ---
Describe 'Run-Agent test run limits' {
    Context 'Tool invocation rate limiting' {
        It 'MAX_TEST_RUNS is set to 2' {
            $MAX_TEST_RUNS | Should -Be 2
        }

        It 'MAX_WRITES is set to 3' {
            $MAX_WRITES | Should -Be 3
        }

        It 'MAX_SEARCHES is set to 6' {
            $MAX_SEARCHES | Should -Be 6
        }

        It 'MAX_COVERAGE_RUNS is set to 1' {
            $MAX_COVERAGE_RUNS | Should -Be 1
        }

        It 'Returns NO_CHANGES when search limit exceeded' {
            Mock -CommandName Write-DebugLog -MockWith {}
            $script:searchCallCount = 0
            Mock -CommandName Invoke-AzureAgent -MockWith {
                $script:searchCallCount++
                '{"tool":"search_files","pattern":"Test"}'
            }
            Mock -CommandName Search-Files -MockWith { @('file1.cs') }

            $script:MAX_SEARCHES = 1
            $result = Run-Agent -Role 'builder' -Deployment 'test' -SystemPrompt 'sys' -InitialContext 'ctx'
            $result | Should -Be 'NO_CHANGES'
        }

        It 'Returns NO_CHANGES when write limit exceeded' {
            Mock -CommandName Write-DebugLog -MockWith {}
            $script:writeCallCount = 0
            Mock -CommandName Invoke-AzureAgent -MockWith {
                $script:writeCallCount++
                '{"tool":"write_file","path":"test.cs","content":"class A{}"}'
            }
            Mock -CommandName Invoke-WriteFile -MockWith { 'FILE_WRITTEN: test.cs (1 lines)' }

            $script:MAX_WRITES = 1
            $result = Run-Agent -Role 'builder' -Deployment 'test' -SystemPrompt 'sys' -InitialContext 'ctx'
            $result | Should -Be 'NO_CHANGES'
        }
    }

    Context 'Tool permissions per role' {
        It 'Builder has search_files permission' {
            $TOOL_PERMISSIONS['builder'] | Should -Contain 'search_files'
        }

        It 'Builder has write_file permission' {
            $TOOL_PERMISSIONS['builder'] | Should -Contain 'write_file'
        }

        It 'Builder has run_tests permission' {
            $TOOL_PERMISSIONS['builder'] | Should -Contain 'run_tests'
        }

        It 'Builder has get_coverage permission' {
            $TOOL_PERMISSIONS['builder'] | Should -Contain 'get_coverage'
        }

        It 'Builder has get_symbols permission' {
            $TOOL_PERMISSIONS['builder'] | Should -Contain 'get_symbols'
        }

        It 'Reviewer has show_diff permission' {
            $TOOL_PERMISSIONS['reviewer'] | Should -Contain 'show_diff'
        }

        It 'Reviewer has get_symbols permission' {
            $TOOL_PERMISSIONS['reviewer'] | Should -Contain 'get_symbols'
        }

        It 'Judge has no tool permissions' {
            $TOOL_PERMISSIONS['judge'].Count | Should -Be 0
        }

        It 'Builder cannot use show_diff' {
            $TOOL_PERMISSIONS['builder'] | Should -Not -Contain 'show_diff'
        }

        It 'Reviewer cannot use write_file' {
            $TOOL_PERMISSIONS['reviewer'] | Should -Not -Contain 'write_file'
        }
    }
}

# --- get_coverage Cobertura XML parsing ---
Describe 'Invoke-GetCoverage' {
    Context 'Parses Cobertura XML coverage report' {
        BeforeAll {
            $script:coverageRepo = Join-Path $TestDrive 'coveragerepo'
            $resultsDir = Join-Path $script:coverageRepo 'TestResults' 'guid123'
            New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null

            # Create a minimal Cobertura XML file
            $coberturaXml = @'
<?xml version="1.0" encoding="utf-8"?>
<coverage line-rate="0.75" branch-rate="0.5" version="1.0">
  <packages>
    <package name="SampleApi" line-rate="0.75">
      <classes>
        <class name="WeatherService" line-rate="0.8" branch-rate="0.5" filename="Services/WeatherService.cs">
          <lines>
            <line number="10" hits="3" />
            <line number="11" hits="2" />
            <line number="12" hits="0" />
            <line number="13" hits="0" />
            <line number="14" hits="1" />
            <line number="20" hits="0" />
          </lines>
        </class>
        <class name="WeatherController" line-rate="1.0" branch-rate="1.0" filename="Controllers/WeatherController.cs">
          <lines>
            <line number="5" hits="1" />
            <line number="6" hits="1" />
          </lines>
        </class>
      </classes>
    </package>
  </packages>
</coverage>
'@
            $coverageFile = Join-Path $resultsDir 'coverage.cobertura.xml'
            $coberturaXml | Out-File $coverageFile -Encoding utf8
        }

        It 'Finds and parses coverage file' {
            # Mock dotnet test to avoid actually running tests
            Mock -CommandName Start-Job -MockWith {
                # Return a mock job object
                [PSCustomObject]@{ Id = 1 }
            }
            Mock -CommandName Wait-Job -MockWith { $true }
            Mock -CommandName Receive-Job -MockWith { "Test run succeeded" }
            Mock -CommandName Stop-Job -MockWith {}
            Mock -CommandName Remove-Job -MockWith {}

            $result = Invoke-GetCoverage -RepoRoot $script:coverageRepo

            $result | Should -Not -BeNullOrEmpty
            $result | Should -Match 'WeatherService'
            $result | Should -Match 'WeatherController'
        }
    }

    Context 'Handles missing coverage data' {
        It 'Returns COVERAGE_NOT_AVAILABLE when no coverage files found' {
            $emptyRepo = Join-Path $TestDrive 'emptycovrepo'
            $emptyResults = Join-Path $emptyRepo 'TestResults'
            New-Item -ItemType Directory -Path $emptyResults -Force | Out-Null

            Mock -CommandName Start-Job -MockWith {
                [PSCustomObject]@{ Id = 2 }
            }
            Mock -CommandName Wait-Job -MockWith { $true }
            Mock -CommandName Receive-Job -MockWith { "Test run succeeded" }
            Mock -CommandName Stop-Job -MockWith {}
            Mock -CommandName Remove-Job -MockWith {}

            $result = Invoke-GetCoverage -RepoRoot $emptyRepo
            $result | Should -Match 'COVERAGE_NOT_AVAILABLE'
        }
    }
}

# --- get_symbols C# output parsing ---
Describe 'Get-CSharpSymbols (agent tool)' {
    Context 'Parses a typical C# service class' {
        BeforeAll {
            $csContent = @'
using System;
using System.Collections.Generic;

namespace SampleApi.Services
{
    public class WeatherService : IWeatherService
    {
        private readonly ILogger<WeatherService> _logger;

        public WeatherService(ILogger<WeatherService> logger)
        {
            _logger = logger;
        }

        public List<WeatherForecast> GetForecasts(int count)
        {
            return new List<WeatherForecast>();
        }

        public WeatherForecast GetById(int id)
        {
            return null;
        }

        private void ValidateInput(int count)
        {
            if (count < 0) throw new ArgumentException();
        }
    }
}
'@
            $script:symbolsFile = Join-Path $TestDrive 'WeatherService.cs'
            $csContent | Out-File $script:symbolsFile -Encoding utf8

            $script:parsedSymbols = Get-CSharpSymbols -Path $script:symbolsFile
        }

        It 'Extracts the namespace' {
            $script:parsedSymbols.Namespace | Should -Be 'SampleApi.Services'
        }

        It 'Extracts the class name' {
            $script:parsedSymbols.Classes.Count | Should -BeGreaterOrEqual 1
            $script:parsedSymbols.Classes[0].Name | Should -Be 'WeatherService'
        }

        It 'Detects public visibility' {
            $script:parsedSymbols.Classes[0].Visibility | Should -Be 'public'
        }

        It 'Detects interface implementation' {
            $script:parsedSymbols.Classes[0].Interfaces | Should -Contain 'IWeatherService'
        }

        It 'Extracts constructor with parameters' {
            $ctors = $script:parsedSymbols.Classes[0].Constructors
            $ctors.Count | Should -BeGreaterOrEqual 1
            $ctors[0].Parameters.Count | Should -BeGreaterOrEqual 1
        }

        It 'Extracts public methods' {
            $methods = $script:parsedSymbols.Classes[0].Methods
            $getForecasts = $methods | Where-Object { $_.Name -eq 'GetForecasts' }
            $getForecasts | Should -Not -BeNullOrEmpty
            $getForecasts.Visibility | Should -Be 'public'
        }

        It 'Extracts private methods' {
            $methods = $script:parsedSymbols.Classes[0].Methods
            $validate = $methods | Where-Object { $_.Name -eq 'ValidateInput' }
            $validate | Should -Not -BeNullOrEmpty
            $validate.Visibility | Should -Be 'private'
        }

        It 'Extracts method return types' {
            $methods = $script:parsedSymbols.Classes[0].Methods
            $getById = $methods | Where-Object { $_.Name -eq 'GetById' }
            $getById | Should -Not -BeNullOrEmpty
            $getById.ReturnType | Should -Be 'WeatherForecast'
        }

        It 'Extracts method parameters' {
            $methods = $script:parsedSymbols.Classes[0].Methods
            $getForecasts = $methods | Where-Object { $_.Name -eq 'GetForecasts' }
            $getForecasts.Parameters.Count | Should -Be 1
            $getForecasts.Parameters[0].Type | Should -Be 'int'
            $getForecasts.Parameters[0].Name | Should -Be 'count'
        }

        It 'Records line numbers for classes' {
            $script:parsedSymbols.Classes[0].Line | Should -BeGreaterThan 0
        }

        It 'Records line numbers for methods' {
            $methods = $script:parsedSymbols.Classes[0].Methods
            $getForecasts = $methods | Where-Object { $_.Name -eq 'GetForecasts' }
            $getForecasts.Line | Should -BeGreaterThan 0
        }
    }

    Context 'Handles non-existent files' {
        It 'Returns empty structure for missing file' {
            $result = Get-CSharpSymbols -Path (Join-Path $TestDrive 'missing.cs')
            $result.Namespace | Should -Be ''
            $result.Classes | Should -HaveCount 0
        }
    }

    Context 'Handles empty files' {
        It 'Returns empty structure for empty file' {
            $emptyFile = Join-Path $TestDrive 'empty.cs'
            '' | Out-File $emptyFile -Encoding utf8

            $result = Get-CSharpSymbols -Path $emptyFile
            $result.Namespace | Should -Be ''
            $result.Classes | Should -HaveCount 0
        }
    }

    Context 'Parses async methods correctly' {
        BeforeAll {
            $asyncContent = @'
namespace AsyncApp
{
    public class AsyncService
    {
        public async Task<string> GetDataAsync(int id)
        {
            return await Task.FromResult("data");
        }
    }
}
'@
            $asyncFile = Join-Path $TestDrive 'AsyncService.cs'
            $asyncContent | Out-File $asyncFile -Encoding utf8

            $script:asyncSymbols = Get-CSharpSymbols -Path $asyncFile
        }

        It 'Detects async flag on methods' {
            $methods = $script:asyncSymbols.Classes[0].Methods
            $getData = $methods | Where-Object { $_.Name -eq 'GetDataAsync' }
            $getData | Should -Not -BeNullOrEmpty
            $getData.Async | Should -BeTrue
        }
    }
}

# --- Invoke-ExplainError categories ---
Describe 'Invoke-ExplainError' {
    Context 'Categorizes common C# errors' {
        It 'Detects NullReferenceException' {
            $result = Invoke-ExplainError -ErrorText "System.NullReferenceException: Object reference not set to an instance of an object."
            $result | Should -Match 'NullReference'
            $result | Should -Match 'mock'
        }

        It 'Detects CS0246 missing type' {
            $result = Invoke-ExplainError -ErrorText "error CS0246: The type or namespace name 'ILogger' could not be found"
            $result | Should -Match 'MissingType'
            $result | Should -Match 'ILogger'
        }

        It 'Detects InvalidOperationException' {
            $result = Invoke-ExplainError -ErrorText "System.InvalidOperationException: Sequence contains no elements"
            $result | Should -Match 'InvalidOperation'
        }

        It 'Detects NotImplementedException' {
            $result = Invoke-ExplainError -ErrorText "System.NotImplementedException: The method or operation is not implemented."
            $result | Should -Match 'NotImplemented'
        }

        It 'Extracts file reference from stack trace' {
            $result = Invoke-ExplainError -ErrorText "at MyApp.Services.UserService.Create() in /src/Services/UserService.cs:line 42"
            $result | Should -Match 'UserService\.cs'
        }

        It 'Returns General for unknown errors' {
            $result = Invoke-ExplainError -ErrorText "Something completely unexpected happened"
            $result | Should -Match 'General'
        }

        It 'Detects CS1002 syntax error' {
            $result = Invoke-ExplainError -ErrorText "error CS1002: ; expected"
            $result | Should -Match 'SyntaxError'
        }
    }
}

# --- New-AgentError structured errors ---
Describe 'New-AgentError' {
    It 'Creates a hashtable with required fields' {
        $error = New-AgentError -Type 'parse_error' -Role 'builder' -Message 'test message'
        $error | Should -BeOfType [hashtable]
        $error.type | Should -Be 'parse_error'
        $error.role | Should -Be 'builder'
        $error.message | Should -Be 'test message'
        $error.timestamp | Should -Not -BeNullOrEmpty
    }

    It 'Timestamp is valid ISO 8601 format' {
        $error = New-AgentError -Type 'api_error' -Role 'reviewer' -Message 'connection failed'
        { [datetime]::Parse($error.timestamp) } | Should -Not -Throw
    }
}

# --- Build-ToolDefinitions (J11) ---
Describe 'Build-ToolDefinitions' {
    It 'Returns tool definitions for builder role' {
        $tools = Build-ToolDefinitions -Role 'builder'
        $tools.Count | Should -BeGreaterThan 0
        $toolNames = $tools | ForEach-Object { $_.function.name }
        $toolNames | Should -Contain 'search_files'
        $toolNames | Should -Contain 'write_file'
        $toolNames | Should -Contain 'run_tests'
        $toolNames | Should -Contain 'get_coverage'
        $toolNames | Should -Contain 'get_symbols'
    }

    It 'Returns limited tool definitions for reviewer role' {
        $tools = Build-ToolDefinitions -Role 'reviewer'
        $tools.Count | Should -Be 2
        $toolNames = $tools | ForEach-Object { $_.function.name }
        $toolNames | Should -Contain 'show_diff'
        $toolNames | Should -Contain 'get_symbols'
    }

    It 'Returns empty for judge role' {
        $tools = Build-ToolDefinitions -Role 'judge'
        $tools.Count | Should -Be 0
    }

    It 'Each tool definition has type and function fields' {
        $tools = Build-ToolDefinitions -Role 'builder'
        foreach ($tool in $tools) {
            $tool.type | Should -Be 'function'
            $tool.function | Should -Not -BeNullOrEmpty
            $tool.function.name | Should -Not -BeNullOrEmpty
            $tool.function.description | Should -Not -BeNullOrEmpty
        }
    }
}
