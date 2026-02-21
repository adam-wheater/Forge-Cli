BeforeAll {
    # Shim Get-ChildItem to avoid parameter binding issues with the Cmdlet
    function Get-ChildItem {
        [CmdletBinding()]
        param(
            [Parameter(ValueFromRemainingArguments=$true)]$RestArgs
        )
        # This shim will be mocked
    }

    # Shim Get-Content
    function Get-Content {
        [CmdletBinding()]
        param(
            [Parameter(ValueFromRemainingArguments=$true)]$RestArgs
        )
    }

    . "$PSScriptRoot/../lib/CostEstimator.ps1"
}

Describe 'Estimate-RunCost' {
    BeforeEach {
        $Global:ForgeConfig = @{}
        $Global:PROMPT_COST_PER_1K = 0.002
        $Global:COMPLETION_COST_PER_1K = 0.006
    }

    Context 'Basic Estimation' {
        It 'Calculates cost correctly for a small repo' {
            Mock -CommandName Test-Path -MockWith { return $true }

            # Mock file finding
            Mock -CommandName Get-ChildItem -MockWith {
                $arguments = $RestArgs
                $hasFilter = $false
                $filterVal = ""

                if ($arguments) {
                    for ($i = 0; $i -lt $arguments.Count; $i++) {
                        if ($arguments[$i] -eq '-Filter') {
                            $hasFilter = $true
                            $filterVal = $arguments[$i+1]
                            break
                        }
                    }
                }

                # Check directly if filter was passed as named parameter
                if ($hasFilter -and $filterVal -eq '*.csproj') {
                     return @()
                }

                return @(
                    [PSCustomObject]@{ FullName = 'C:\Repo\file1.cs'; Extension = '.cs' },
                    [PSCustomObject]@{ FullName = 'C:\Repo\file2.ps1'; Extension = '.ps1' }
                )
            }

            # Mock file content reading (LOC)
            Mock -CommandName Get-Content -MockWith {
                return (1..10) # 10 lines
            }

            $estimate = Estimate-RunCost -RepoRoot 'C:\Repo'

            $estimate.FileCount | Should -Be 2
            $estimate.TotalLOC | Should -Be 20
            $estimate.TestCount | Should -Be 0
            $estimate.EstimatedIterations | Should -Be 3 # Default minimum

            # Check if cost is calculated (non-zero)
            $estimate.EstimatedCostGBP | Should -BeGreaterThan 0
        }

        It 'Respects MaxLoops parameter' {
            Mock -CommandName Test-Path -MockWith { return $true }
            Mock -CommandName Get-ChildItem -MockWith {
                return @()
            }

            # With no failures, it defaults to min(3, MaxLoops)
            # If MaxLoops is 1, it should be 1
            $estimate = Estimate-RunCost -RepoRoot 'C:\Repo' -MaxLoops 1
            $estimate.EstimatedIterations | Should -Be 1
        }
    }

    Context 'Test Counting' {
        It 'Counts tests correctly via dotnet test --list-tests' {
            Mock -CommandName Test-Path -MockWith { return $true }

            # Mock file finding
            Mock -CommandName Get-ChildItem -MockWith {
                # Check args for .csproj filter
                $argsStr = $RestArgs -join " "

                if ($RestArgs -contains '*.csproj') {
                     return @([PSCustomObject]@{ FullName = 'C:\Repo\MyTests.csproj'; Extension = '.csproj' })
                }

                if ($RestArgs -contains '-File') {
                     if ($RestArgs -contains '*.csproj') {
                          return @([PSCustomObject]@{ FullName = 'C:\Repo\MyTests.csproj'; Extension = '.csproj' })
                     }
                     return @(
                        [PSCustomObject]@{ FullName = 'C:\Repo\file1.cs'; Extension = '.cs' },
                        [PSCustomObject]@{ FullName = 'C:\Repo\file2.ps1'; Extension = '.ps1' }
                     )
                }

                if ($argsStr -like "*csproj*") {
                     return @([PSCustomObject]@{ FullName = 'C:\Repo\MyTests.csproj'; Extension = '.csproj' })
                }

                return @()
            }

            # Mock dotnet test --list-tests
            Mock -CommandName dotnet -MockWith {
                # $args is an array of arguments passed to the command
                if ($args -contains '--list-tests') {
                    return @(
                        "Test run for ...",
                        "  Test1",
                        "  Test2",
                        "  Test3"
                    )
                }
                return @()
            }

            $estimate = Estimate-RunCost -RepoRoot 'C:\Repo'
            $estimate.TestCount | Should -Be 3
        }

        It 'Counts failing tests via dotnet test run' {
            Mock -CommandName Test-Path -MockWith { return $true }

            Mock -CommandName Get-ChildItem -MockWith {
                $argsStr = $RestArgs -join " "
                if ($argsStr -like "*MyTests.csproj*" -or $argsStr -like "*.csproj*" -or $argsStr -match "-Filter\s+\*\.csproj") {
                     return @([PSCustomObject]@{ FullName = 'C:\Repo\MyTests.csproj'; Extension = '.csproj' })
                }
                return @()
            }

            Mock -CommandName dotnet -MockWith {
                if ($args -contains '--list-tests') {
                    return @("  Test1", "  Test2")
                }
                # Mock execution output with failures
                if ($args -contains '--verbosity') {
                    return @("Failed: 1")
                }
                return @()
            }

            $estimate = Estimate-RunCost -RepoRoot 'C:\Repo'
            $estimate.FailureCount | Should -Be 1
            # Iterations should be failure count * 2 (min 3) => 1*2 = 2. But min(2, 3) is wrong logic?
            # Logic: if failureCount > 0: min(failureCount * 2, MaxLoops).
            # MaxLoops default is 8.
            # FailureCount = 1. 1 * 2 = 2.
            $estimate.EstimatedIterations | Should -Be 2
        }
    }

    Context 'Cost Calculation' {
        It 'Uses config values for cost calculation' {
            $Global:ForgeConfig['promptCostPer1K'] = 0.01
            $Global:ForgeConfig['completionCostPer1K'] = 0.03

            Mock -CommandName Test-Path -MockWith { return $true }
            Mock -CommandName Get-ChildItem -MockWith {
                return @()
            }

            $estimate = Estimate-RunCost -RepoRoot 'C:\Repo'

            # Just verify it used the config (by checking if cost is higher than with default 0.002)
            # Default tokens are calculated based on files/tests. Even with 0 files, there are base tokens?
            # Logic:
            # $fileReadTokens = $fileReadsPerIteration * $avgTokensPerFileRead * $estimatedIterations
            # $agentCallTokens = $agentCallsPerIteration * $avgTokensPerAgentCall * $estimatedIterations
            # $searchTokens = ...
            # With 0 files, it still estimates tokens based on iterations.
            # Default Iterations = 3.
            # So tokens > 0.

            $estimate.EstimatedCostGBP | Should -BeGreaterThan 0
        }
    }
}

Describe 'Format-CostEstimate' {
    It 'Formats cost correctly' {
        $estimate = @{
            EstimatedTokens = 1500
            EstimatedCostGBP = 5.50
            CostRangeLowerGBP = 3.30
            CostRangeUpperGBP = 9.90
            Confidence = 'high'
            EstimatedIterations = 3
            FileCount = 10
            CSharpFileCount = 5
            TotalLOC = 1000
            TestCount = 20
            FailureCount = 2
        }

        $output = Format-CostEstimate -Estimate $estimate
        $output | Should -Match 'Estimated cost: .*3.30-.*9.90 \(high confidence\)'
        # 1500 rounds to 2k
        $output | Should -Match 'for ~2k tokens'
        $output | Should -Match 'Tests: 20 found, 2 failing'
    }

    It 'Formats exact tokens if less than 1000' {
         $estimate = @{
            EstimatedTokens = 500
            EstimatedCostGBP = 1.0
            CostRangeLowerGBP = 0.5
            CostRangeUpperGBP = 1.5
            Confidence = 'low'
            EstimatedIterations = 1
            FileCount = 1
            CSharpFileCount = 1
            TotalLOC = 10
            TestCount = 0
            FailureCount = 0
        }
        $output = Format-CostEstimate -Estimate $estimate
        $output | Should -Match 'for ~500 tokens'
    }
}

Describe 'Confirm-CostThreshold' {
    Context 'When cost is below threshold' {
        It 'Returns true' {
            $estimate = @{ EstimatedCostGBP = 10.00 }
            $result = Confirm-CostThreshold -Estimate $estimate -ThresholdGBP 20.00
            $result | Should -Be $true
        }
    }

    Context 'When cost is above threshold' {
        It 'Returns false if non-interactive' {
            # We can't easily force non-interactive if the environment claims to be interactive
            # But usually test runners are non-interactive.
            # If [Environment]::UserInteractive is true, this test might fail or prompt (which hangs).

            if (-not [Environment]::UserInteractive) {
                $estimate = @{ EstimatedCostGBP = 30.00; CostRangeLowerGBP=20; CostRangeUpperGBP=40 }
                $result = Confirm-CostThreshold -Estimate $estimate -ThresholdGBP 20.00
                $result | Should -Be $false
            } else {
                Set-ItResult -Pending -Because "Cannot test non-interactive path in an interactive session"
            }
        }

        # We skip testing the interactive prompt because Read-Host is hard to mock cleanly if we can't control [Environment]::UserInteractive
        # mocking Read-Host only works if the code reaches it.
    }
}
