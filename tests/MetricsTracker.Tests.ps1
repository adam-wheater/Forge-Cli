Describe 'MetricsTracker' {
    BeforeAll {
        # Dot-source the module. Assuming we run from repo root, PSScriptRoot in this file
        # will be <repo>/tests/. So ../lib/MetricsTracker.ps1 is correct.
        . "$PSScriptRoot/../lib/MetricsTracker.ps1"

        $TestOutputPath = Join-Path $PSScriptRoot "tmp_metrics_test"
        if (-not (Test-Path $TestOutputPath)) {
            New-Item -ItemType Directory -Path $TestOutputPath -Force | Out-Null
        }
        $Global:MemoryRoot = Join-Path $TestOutputPath "memory"
    }

    AfterAll {
        if (Test-Path $TestOutputPath) {
            Remove-Item -Path $TestOutputPath -Recurse -Force
        }
    }

    BeforeEach {
        $Global:MetricsSession = $null
        $Global:MetricsEvents = @()

        Mock Get-TotalTokens { return 1000 }
        Mock Get-CurrentCostGBP { return 0.50 }
    }

    Context 'Initialize-Metrics' {
        It 'Initializes session and events' {
            Initialize-Metrics
            $Global:MetricsSession | Should -Not -BeNullOrEmpty
            $Global:MetricsSession.SessionId | Should -Not -BeNullOrEmpty
            $Global:MetricsSession.StartTime | Should -BeOfType [DateTime]
            $Global:MetricsEvents | Should -BeOfType [System.Array]
            $Global:MetricsEvents.Count | Should -Be 0
        }
    }

    Context 'Add-MetricEvent' {
        It 'Adds an event correctly' {
            Initialize-Metrics
            Add-MetricEvent -Event "iteration_start" -Data @{ iteration = 1 }
            $Global:MetricsEvents.Count | Should -Be 1
            $Global:MetricsEvents[0].Type | Should -Be "iteration_start"
            $Global:MetricsEvents[0].Data.iteration | Should -Be 1
        }

        It 'Warns if not initialized' {
            Mock Write-Warning
            Add-MetricEvent -Event "iteration_start" -Data @{}
            Should -Invoke -CommandName Write-Warning -Times 1 -ParameterFilter { $Message -like "*Metrics not initialized*" }
            $Global:MetricsEvents.Count | Should -Be 0
        }

        It 'Validates event type' {
            Initialize-Metrics
            { Add-MetricEvent -Event "invalid_type" -Data @{} } | Should -Throw
        }
    }

    Context 'Save-Metrics' {
        It 'Saves metrics to file and returns object' {
            Initialize-Metrics

            # Set fixed start time for duration calc
            # We capture current time to use in Mock
            $now = (Get-Date).ToUniversalTime()
            $Global:MetricsSession.StartTime = $now.AddMinutes(-1)

            # Mock Get-Date to return our fixed 'now' time
            Mock Get-Date { return $now }

            Add-MetricEvent -Event "iteration_start" -Data @{}
            Add-MetricEvent -Event "patch_generated" -Data @{}
            Add-MetricEvent -Event "build_result" -Data @{ success = $true }

            $outputPath = Join-Path $TestOutputPath "metrics.json"
            $metrics = Save-Metrics -OutputPath $outputPath

            Test-Path $outputPath | Should -Be $true

            $content = Get-Content $outputPath | ConvertFrom-Json

            $content.sessionId | Should -Be $Global:MetricsSession.SessionId
            $content.iterationsUsed | Should -Be 1
            $content.patchesTried | Should -Be 1
            $content.buildSuccesses | Should -Be 1
            $content.successRate | Should -Be 100

            # Check duration is approx 60 seconds
            # Note: Floating point comparison
            [Math]::Round($metrics.totalTimeSeconds) | Should -Be 60

            $metrics.iterationsUsed | Should -Be 1
        }

        It 'Warns if not initialized' {
            Mock Write-Warning
            Save-Metrics
            Should -Invoke -CommandName Write-Warning -Times 1 -ParameterFilter { $Message -like "*Metrics not initialized*" }
        }
    }

    Context 'Get-MetricsSummary' {
        It 'Returns summary string' {
            Initialize-Metrics
            Add-MetricEvent -Event "iteration_start" -Data @{}

            $summary = Get-MetricsSummary
            $summary | Should -Match "Forge Run Metrics"
            $summary | Should -Match "Iterations:\s+1"
        }
    }

    Context 'Save-SuccessMetrics' {
        It 'Saves success metrics to memory root' {
            Initialize-Metrics
            Add-MetricEvent -Event "iteration_start" -Data @{}
            Add-MetricEvent -Event "build_result" -Data @{ success = $true }

            $repoName = "TestRepo"
            Save-SuccessMetrics -RepoName $repoName -MemoryRoot $Global:MemoryRoot

            $dateStr = (Get-Date).ToString("yyyy-MM-dd")
            $expectedPath = Join-Path $Global:MemoryRoot $repoName "metrics" "$dateStr.json"

            Test-Path $expectedPath | Should -Be $true

            $content = Get-Content $expectedPath | ConvertFrom-Json
            $content | Should -BeOfType [System.Array]
            $content.Count | Should -Be 1
            $content[0].success | Should -Be $true
        }

        It 'Appends to existing metrics file' {
            Initialize-Metrics
            $repoName = "TestRepo2"

            # First run
            Save-SuccessMetrics -RepoName $repoName -MemoryRoot $Global:MemoryRoot

            # Second run
            Initialize-Metrics # New session
            Save-SuccessMetrics -RepoName $repoName -MemoryRoot $Global:MemoryRoot

            $dateStr = (Get-Date).ToString("yyyy-MM-dd")
            $expectedPath = Join-Path $Global:MemoryRoot $repoName "metrics" "$dateStr.json"

            $content = Get-Content $expectedPath | ConvertFrom-Json
            $content.Count | Should -Be 2
        }
    }

    Context 'Get-SuccessHistory' {
        It 'Retrieves history sorted correctly' {
            $repoName = "HistoryRepo"
            $metricsDir = Join-Path $Global:MemoryRoot $repoName "metrics"
            New-Item -ItemType Directory -Path $metricsDir -Force | Out-Null

            # Create dummy files
            $d1 = @{ date = "2023-01-01"; success = $true }
            $d2 = @{ date = "2023-01-02"; success = $false }

            # Note: Writing single objects, but Get-SuccessHistory handles single objects or arrays
            ($d1 | ConvertTo-Json) | Out-File (Join-Path $metricsDir "2023-01-01.json")
            ($d2 | ConvertTo-Json) | Out-File (Join-Path $metricsDir "2023-01-02.json")

            $history = Get-SuccessHistory -RepoName $repoName -MemoryRoot $Global:MemoryRoot

            $history.Count | Should -Be 2
            $history[0].date | Should -Be "2023-01-02" # Most recent first
            $history[1].date | Should -Be "2023-01-01"
        }
    }

    Context 'Get-SuccessTrend' {
        It 'Calculates improving trend' {
            $repoName = "TrendRepo"
            $metricsDir = Join-Path $Global:MemoryRoot $repoName "metrics"
            New-Item -ItemType Directory -Path $metricsDir -Force | Out-Null

            # Recent: 2 success (100%), Older: 2 failure (0%) -> Improving
            $data = @(
                @{ date = "2023-01-04"; success = $true; costGBP = 0.1 },
                @{ date = "2023-01-03"; success = $true; costGBP = 0.1 },
                @{ date = "2023-01-02"; success = $false; costGBP = 0.1 },
                @{ date = "2023-01-01"; success = $false; costGBP = 0.1 }
            )

            foreach ($d in $data) {
                ($d | ConvertTo-Json) | Out-File (Join-Path $metricsDir "$($d.date).json")
            }

            $trend = Get-SuccessTrend -RepoName $repoName -MemoryRoot $Global:MemoryRoot

            $trend.Trend | Should -Be "improving"
            $trend.RecentSuccessRate | Should -Be 100.0
            $trend.OlderSuccessRate | Should -Be 0.0
        }

        It 'Handles insufficient data' {
             $repoName = "EmptyRepo"
             $trend = Get-SuccessTrend -RepoName $repoName -MemoryRoot $Global:MemoryRoot
             $trend.Trend | Should -Be "insufficient_data"
        }
    }

    Context 'Export-MetricsHtml' {
        It 'Generates HTML report' {
            $metrics = @{
                sessionId = "test-session"
                startTime = "2023-01-01T00:00:00Z"
                endTime = "2023-01-01T00:01:00Z"
                totalTimeSeconds = 60
                iterationsUsed = 1
                tokensConsumed = 100
                costGBP = 0.01
                patchesTried = 1
                testsFixed = 0
                successRate = 100
                events = @()
            }

            $outputPath = Join-Path $TestOutputPath "report.html"
            Export-MetricsHtml -Metrics $metrics -OutputPath $outputPath

            Test-Path $outputPath | Should -Be $true
            $content = Get-Content $outputPath
            $content | Should -Match "<html"
            $content | Should -Match "test-session"
        }
    }
}
