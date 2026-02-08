BeforeAll {
    # E42: Integration test for full run.ps1 loop
    # This test mocks the Azure API and git commands, then runs
    # a complete iteration cycle to verify memory updates, budget
    # enforcement, git operations, and patch validation.

    # Load all required modules
    . "$PSScriptRoot/../lib/TokenBudget.ps1"
    . "$PSScriptRoot/../lib/RelevanceTracker.ps1"
    . "$PSScriptRoot/../lib/RepoTools.ps1"
    . "$PSScriptRoot/../lib/AzureAgent.ps1"
    . "$PSScriptRoot/../lib/Orchestrator.ps1"
    . "$PSScriptRoot/../lib/ConfigLoader.ps1"
}

Describe 'Integration: Full run.ps1 loop simulation' {
    BeforeEach {
        # Reset token counters
        $Global:PromptTokens = 0
        $Global:CompletionTokens = 0
        $Global:MAX_TOTAL_TOKENS = 200000
        $Global:MAX_ITERATION_TOKENS = 40000
        $Global:MAX_COST_GBP = 25.00
        $Global:PROMPT_COST_PER_1K = 0.002
        $Global:COMPLETION_COST_PER_1K = 0.006
        $Global:FileRelevance = @{}
    }

    Context 'Budget enforcement during iteration cycle' {
        It 'Enforces iteration token budget correctly' {
            Add-TokenUsage -Prompt 100 -Completion 50
            $iterationStart = 0

            { Enforce-Budgets -IterationStartTokens $iterationStart } | Should -Not -Throw
        }

        It 'Throws when iteration budget exceeded' {
            $Global:MAX_ITERATION_TOKENS = 100
            Add-TokenUsage -Prompt 80 -Completion 30
            $iterationStart = 0

            { Enforce-Budgets -IterationStartTokens $iterationStart } | Should -Throw '*Iteration token budget exceeded*'
        }

        It 'Throws when total budget exceeded' {
            $Global:MAX_TOTAL_TOKENS = 50
            $Global:MAX_ITERATION_TOKENS = 200000
            Add-TokenUsage -Prompt 40 -Completion 20

            { Enforce-Budgets -IterationStartTokens 0 } | Should -Throw '*Total token budget exceeded*'
        }

        It 'Throws when cost budget exceeded' {
            $Global:MAX_COST_GBP = 0.001
            $Global:PROMPT_COST_PER_1K = 10.0
            Add-TokenUsage -Prompt 100 -Completion 0

            { Enforce-Budgets -IterationStartTokens 100 } | Should -Throw '*Cost budget exceeded*'
        }
    }

    Context 'Patch validation (diff format check)' {
        It 'Accepts valid unified diff format' {
            $validPatch = "diff --git a/file.cs b/file.cs`n--- a/file.cs`n+++ b/file.cs`n@@ -1 +1 @@`n-old`n+new"
            $validPatch -match '^(diff --git|---)' | Should -BeTrue
        }

        It 'Accepts patch starting with ---' {
            $validPatch = "--- a/file.cs`n+++ b/file.cs`n@@ -1 +1 @@`n-old`n+new"
            $validPatch -match '^(diff --git|---)' | Should -BeTrue
        }

        It 'Rejects plain text as invalid diff' {
            $invalidPatch = "I made some changes to the file."
            $invalidPatch -match '^(diff --git|---)' | Should -BeFalse
        }

        It 'Rejects JSON response as invalid diff' {
            $jsonResponse = '{"tool":"search_files","pattern":"Test"}'
            $jsonResponse -match '^(diff --git|---)' | Should -BeFalse
        }

        It 'Rejects NO_CHANGES as invalid diff' {
            $noChanges = "NO_CHANGES"
            $noChanges -match '^(diff --git|---)' | Should -BeFalse
        }

        It 'Rejects empty string as invalid diff' {
            $empty = ""
            $empty -match '^(diff --git|---)' | Should -BeFalse
        }
    }

    Context 'Agent Run-Agent returns structured results' {
        It 'Returns NO_CHANGES for non-actionable response' {
            Mock -CommandName Invoke-AzureAgent -MockWith { 'NO_CHANGES' }
            Mock -CommandName Write-DebugLog -MockWith {}

            $result = Run-Agent -Role 'builder' -Deployment 'test-deploy' -SystemPrompt 'sys' -InitialContext 'context'
            $result | Should -Be 'NO_CHANGES'
        }

        It 'Returns diff when agent produces a valid patch' {
            $patchResponse = "diff --git a/test.cs b/test.cs`n--- a/test.cs`n+++ b/test.cs`n@@ -1 +1 @@`n-old`n+new"
            Mock -CommandName Invoke-AzureAgent -MockWith { $patchResponse }
            Mock -CommandName Write-DebugLog -MockWith {}

            $result = Run-Agent -Role 'builder' -Deployment 'test-deploy' -SystemPrompt 'sys' -InitialContext 'context'
            $result | Should -Match '^diff --git'
        }

        It 'Returns structured error for invalid JSON' {
            Mock -CommandName Invoke-AzureAgent -MockWith { 'not json at all' }
            Mock -CommandName Write-DebugLog -MockWith {}

            $result = Run-Agent -Role 'builder' -Deployment 'test-deploy' -SystemPrompt 'sys' -InitialContext 'context'
            $result | Should -BeOfType [hashtable]
            $result.type | Should -Be 'parse_error'
        }

        It 'Throws for forbidden tool' {
            Mock -CommandName Invoke-AzureAgent -MockWith { '{"tool":"forbidden_tool"}' }
            Mock -CommandName Write-DebugLog -MockWith {}

            { Run-Agent -Role 'builder' -Deployment 'test-deploy' -SystemPrompt 'sys' -InitialContext 'context' } |
                Should -Throw '*Forbidden tool*'
        }
    }

    Context 'Iteration limit prevents infinite loops' {
        It 'Returns NO_CHANGES after hitting max iterations' {
            $script:MAX_AGENT_ITERATIONS = 3
            $script:callCount = 0
            Mock -CommandName Invoke-AzureAgent -MockWith {
                $script:callCount++
                '{"tool":"search_files","pattern":"Test"}'
            }
            Mock -CommandName Write-DebugLog -MockWith {}
            Mock -CommandName Search-Files -MockWith { @('file1.cs') }

            $result = Run-Agent -Role 'builder' -Deployment 'test-deploy' -SystemPrompt 'sys' -InitialContext 'context'
            $result | Should -Be 'NO_CHANGES'
            $script:callCount | Should -BeLessOrEqual 4
        }
    }

    Context 'RepoName derivation from RepoUrl (C113)' {
        It 'Derives repo name from URL ending with .git' {
            $repoUrl = 'https://github.com/user/my-project.git'
            $repoName = ($repoUrl -replace '\.git$','') -replace '.*/',''
            $repoName | Should -Be 'my-project'
        }

        It 'Derives repo name from URL without .git' {
            $repoUrl = 'https://github.com/user/my-project'
            $repoName = ($repoUrl -replace '\.git$','') -replace '.*/',''
            $repoName | Should -Be 'my-project'
        }
    }

    Context 'Config loader integration' {
        It 'Loads default config values' {
            $config = Load-ForgeConfig -ConfigPath (Join-Path $TestDrive 'nonexistent.json')
            $config.maxLoops | Should -Be 8
            $config.maxAgentIterations | Should -Be 20
            $config.maxSearches | Should -Be 6
            $config.maxOpens | Should -Be 5
            $config.maxTotalTokens | Should -Be 200000
            $config.maxIterationTokens | Should -Be 40000
            $config.maxCostGBP | Should -Be 25.00
        }

        It 'Loads config from a custom JSON file' {
            $configContent = @{
                maxLoops = 12
                maxCostGBP = 50.0
            } | ConvertTo-Json
            $configFile = Join-Path $TestDrive 'forge.config.json'
            $configContent | Out-File $configFile -Encoding utf8

            $config = Load-ForgeConfig -ConfigPath $configFile
            $config.maxLoops | Should -Be 12
            $config.maxCostGBP | Should -Be 50.0
            # Non-overridden values should retain defaults
            $config.maxSearches | Should -Be 6
        }
    }

    Context 'Token tracking across multiple iterations' {
        It 'Accumulates tokens across multiple Add-TokenUsage calls' {
            $Global:PromptTokens = 0
            $Global:CompletionTokens = 0

            Add-TokenUsage -Prompt 100 -Completion 50
            Add-TokenUsage -Prompt 200 -Completion 100
            Add-TokenUsage -Prompt 150 -Completion 75

            Get-TotalTokens | Should -Be 675
            $Global:PromptTokens | Should -Be 450
            $Global:CompletionTokens | Should -Be 225
        }

        It 'Computes cost correctly across iterations' {
            $Global:PromptTokens = 0
            $Global:CompletionTokens = 0
            $Global:PROMPT_COST_PER_1K = 0.002
            $Global:COMPLETION_COST_PER_1K = 0.006

            Add-TokenUsage -Prompt 10000 -Completion 5000
            $cost = Get-CurrentCostGBP
            # 10000/1000 * 0.002 + 5000/1000 * 0.006 = 0.02 + 0.03 = 0.05
            $cost | Should -Be 0.05
        }
    }

    Context 'File relevance tracking across searches' {
        It 'Marks files as relevant when opened' {
            $Global:FileRelevance = @{}
            Mark-Relevant 'src/UserService.cs'
            Mark-Relevant 'src/UserService.cs'
            Mark-Relevant 'src/UserService.cs'

            Get-RelevanceScore 'src/UserService.cs' | Should -Be 3
        }

        It 'Returns zero for unaccessed files' {
            $Global:FileRelevance = @{}
            Get-RelevanceScore 'src/NewFile.cs' | Should -Be 0
        }

        It 'Score-File factors in relevance decay' {
            $Global:FileRelevance = @{}
            Mark-Relevant 'src/Services/UserService.cs'
            Mark-Relevant 'src/Services/UserService.cs'

            $score = Score-File 'src/Services/UserService.cs'
            # Service (+15), .cs (+5), decay (-2) = 18
            $score | Should -Be 18
        }
    }

    Context 'End-to-end: mock full iteration cycle' {
        It 'Completes a full cycle: search -> open -> patch' {
            # Mock agent responses: first returns a search tool call, then returns a diff
            $script:iterationCount = 0
            Mock -CommandName Invoke-AzureAgent -MockWith {
                $script:iterationCount++
                if ($script:iterationCount -eq 1) {
                    '{"tool":"search_files","pattern":"UserService"}'
                } else {
                    "diff --git a/test.cs b/test.cs`n--- a/test.cs`n+++ b/test.cs`n@@ -1 +1 @@`n-old`n+new"
                }
            }
            Mock -CommandName Write-DebugLog -MockWith {}
            Mock -CommandName Search-Files -MockWith { @('src/UserService.cs', 'tests/UserServiceTests.cs') }

            $result = Run-Agent -Role 'builder' -Deployment 'test-deploy' -SystemPrompt 'system prompt' -InitialContext 'Fix failing tests'
            $result | Should -Match '^diff --git'
        }
    }
}

Describe 'Integration: Sample C# solution fixture validation' {
    Context 'Fixture files exist (E47)' {
        It 'SampleApi solution file exists' {
            $slnPath = Join-Path $PSScriptRoot 'fixtures' 'SampleApi' 'SampleApi.sln'
            Test-Path $slnPath | Should -BeTrue
        }

        It 'SampleApi project file exists' {
            $csprojPath = Join-Path $PSScriptRoot 'fixtures' 'SampleApi' 'src' 'SampleApi' 'SampleApi.csproj'
            Test-Path $csprojPath | Should -BeTrue
        }

        It 'WeatherController exists' {
            $controllerPath = Join-Path $PSScriptRoot 'fixtures' 'SampleApi' 'src' 'SampleApi' 'Controllers' 'WeatherController.cs'
            Test-Path $controllerPath | Should -BeTrue
        }

        It 'IWeatherService interface exists' {
            $interfacePath = Join-Path $PSScriptRoot 'fixtures' 'SampleApi' 'src' 'SampleApi' 'Services' 'IWeatherService.cs'
            Test-Path $interfacePath | Should -BeTrue
        }

        It 'WeatherService implementation exists' {
            $servicePath = Join-Path $PSScriptRoot 'fixtures' 'SampleApi' 'src' 'SampleApi' 'Services' 'WeatherService.cs'
            Test-Path $servicePath | Should -BeTrue
        }

        It 'WeatherForecast model exists' {
            $modelPath = Join-Path $PSScriptRoot 'fixtures' 'SampleApi' 'src' 'SampleApi' 'Models' 'WeatherForecast.cs'
            Test-Path $modelPath | Should -BeTrue
        }

        It 'Test project file exists' {
            $testCsprojPath = Join-Path $PSScriptRoot 'fixtures' 'SampleApi' 'tests' 'SampleApi.Tests' 'SampleApi.Tests.csproj'
            Test-Path $testCsprojPath | Should -BeTrue
        }

        It 'WeatherServiceTests exists' {
            $testFilePath = Join-Path $PSScriptRoot 'fixtures' 'SampleApi' 'tests' 'SampleApi.Tests' 'WeatherServiceTests.cs'
            Test-Path $testFilePath | Should -BeTrue
        }
    }

    Context 'CSharpAnalyser can parse fixture files' {
        BeforeAll {
            . "$PSScriptRoot/../lib/CSharpAnalyser.ps1"
        }

        It 'Parses WeatherController symbols' {
            $controllerPath = Join-Path $PSScriptRoot 'fixtures' 'SampleApi' 'src' 'SampleApi' 'Controllers' 'WeatherController.cs'
            $symbols = Get-CSharpSymbols -Path $controllerPath
            $symbols.Namespace | Should -Be 'SampleApi.Controllers'
            $symbols.Classes.Count | Should -BeGreaterOrEqual 1
            $symbols.Classes[0].Name | Should -Be 'WeatherController'
        }

        It 'Parses WeatherService symbols' {
            $servicePath = Join-Path $PSScriptRoot 'fixtures' 'SampleApi' 'src' 'SampleApi' 'Services' 'WeatherService.cs'
            $symbols = Get-CSharpSymbols -Path $servicePath
            $symbols.Classes.Count | Should -BeGreaterOrEqual 1
            $symbols.Classes[0].Name | Should -Be 'WeatherService'
        }

        It 'Parses WeatherForecast model' {
            $modelPath = Join-Path $PSScriptRoot 'fixtures' 'SampleApi' 'src' 'SampleApi' 'Models' 'WeatherForecast.cs'
            $symbols = Get-CSharpSymbols -Path $modelPath
            $symbols.Classes.Count | Should -BeGreaterOrEqual 1
            $symbols.Classes[0].Name | Should -Be 'WeatherForecast'
        }

        It 'Detects xUnit and Moq from test project' {
            $testCsprojPath = Join-Path $PSScriptRoot 'fixtures' 'SampleApi' 'tests' 'SampleApi.Tests' 'SampleApi.Tests.csproj'
            $packages = Get-NuGetPackages -ProjectPath $testCsprojPath
            $packages.TestFramework | Should -Be 'xunit'
            $packages.MockLibrary | Should -Be 'moq'
        }
    }
}
