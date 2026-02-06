BeforeAll {
    . "$PSScriptRoot/../lib/RepoMemory.ps1"
    $Global:MemoryRoot = Join-Path $TestDrive "memory"
    New-Item -ItemType Directory -Path $Global:MemoryRoot -Force | Out-Null
}

Describe "Read-MemoryFile" {
    Context "When file exists" {
        It "Returns parsed JSON" {
            $data = @{ foo = "bar"; count = 42 }
            $data | ConvertTo-Json | Out-File (Join-Path $Global:MemoryRoot "test.json") -Encoding utf8

            $result = Read-MemoryFile "test.json"
            $result.foo | Should -Be "bar"
            $result.count | Should -Be 42
        }
    }

    Context "When file does not exist" {
        It "Returns null" {
            $result = Read-MemoryFile "nonexistent.json"
            $result | Should -BeNullOrEmpty
        }
    }
}

Describe "Write-MemoryFile" {
    It "Creates file with valid JSON" {
        $data = @{ name = "test"; items = @(1, 2, 3) }
        Write-MemoryFile "output.json" $data

        $path = Join-Path $Global:MemoryRoot "output.json"
        Test-Path $path | Should -BeTrue

        $loaded = Get-Content $path -Raw | ConvertFrom-Json
        $loaded.name | Should -Be "test"
        $loaded.items.Count | Should -Be 3
    }

    It "Creates parent directory if missing" {
        $Global:MemoryRoot = Join-Path $TestDrive "new-memory-dir"
        Write-MemoryFile "deep.json" @{ ok = $true }

        $path = Join-Path $Global:MemoryRoot "deep.json"
        Test-Path $path | Should -BeTrue

        # Restore
        $Global:MemoryRoot = Join-Path $TestDrive "memory"
    }
}

Describe "Save-RunState" {
    It "Persists iteration and failure data" {
        $state = Save-RunState -Iteration 5 -Failures @("TestA", "TestB") -BuildOk $true -TestOk $false

        $state.iteration | Should -Be 5
        $state.lastFailures.Count | Should -Be 2
        $state.lastBuildOk | Should -BeTrue
        $state.lastTestOk | Should -BeFalse

        $loaded = Read-MemoryFile "run-state.json"
        $loaded.iteration | Should -Be 5
    }

    It "Handles empty failures" {
        $state = Save-RunState -Iteration 1

        $state.lastFailures.Count | Should -Be 0
        $state.lastBuildOk | Should -BeTrue
        $state.lastTestOk | Should -BeTrue
    }
}

Describe "Update-Heuristics" {
    BeforeEach {
        # Reset heuristics file
        $h = @{ coFailures = @{}; fragileFiles = @(); flakyTests = @(); knownFixes = @{} }
        Write-MemoryFile "heuristics.json" $h
    }

    It "Tracks fragile files" {
        Update-Heuristics -FailedFiles @("Service.ps1", "Helper.ps1")

        $h = Read-MemoryFile "heuristics.json"
        $h.fragileFiles | Should -Contain "Service.ps1"
        $h.fragileFiles | Should -Contain "Helper.ps1"
    }

    It "Tracks flaky tests" {
        Update-Heuristics -FailedTests @("Test.CanCreate", "Test.CanDelete")

        $h = Read-MemoryFile "heuristics.json"
        $h.flakyTests | Should -Contain "Test.CanCreate"
        $h.flakyTests | Should -Contain "Test.CanDelete"
    }

    It "Records known fixes" {
        Update-Heuristics -FailedTests @("Test.Broken") -FixDescription "Added null check"

        $h = Read-MemoryFile "heuristics.json"
        $h.knownFixes."Test.Broken" | Should -Be "Added null check"
    }

    It "Limits fragile files to 20" {
        for ($i = 1; $i -le 25; $i++) {
            Update-Heuristics -FailedFiles @("File$i.ps1")
        }

        $h = Read-MemoryFile "heuristics.json"
        $h.fragileFiles.Count | Should -BeLessOrEqual 20
    }
}

Describe "Get-MemorySummary" {
    BeforeAll {
        # Set up memory files for summary testing
        Write-MemoryFile "repo-map.json" @{
            projectType  = "powershell"
            solution     = $null
            coreModules  = @(@{ name = "AgentA" }, @{ name = "AgentB" })
            testProjects = @("./tests/AgentA.Tests.ps1")
            entryPoints  = @("./run.ps1")
        }
        Write-MemoryFile "run-state.json" @{
            iteration       = 3
            lastFailures    = @("TestX.Fails")
            recentFiles     = @("lib/AgentA.ps1")
            lastDiffSummary = "Fixed null check"
            lastAttempts    = @("Fix mocks")
            lastBuildOk     = $true
            lastTestOk      = $false
        }
        Write-MemoryFile "code-intel.json" @{
            callGraph         = @{}
            testToCodeMap     = @{}
            recentlyChanged   = @("lib/AgentA.ps1", "tests/AgentA.Tests.ps1")
            failingTestToCode = @{}
        }
        Write-MemoryFile "heuristics.json" @{
            coFailures   = @{}
            fragileFiles = @("lib/AgentA.ps1")
            flakyTests   = @("TestX.Fails")
            knownFixes   = @{ "TestX.Fails" = "Add null check in constructor" }
        }
    }

    It "Returns string starting with REPO_MEMORY" {
        $summary = Get-MemorySummary
        $summary | Should -Match "^REPO_MEMORY:"
    }

    It "Includes project type" {
        $summary = Get-MemorySummary
        $summary | Should -Match "Project: powershell"
    }

    It "Includes module names" {
        $summary = Get-MemorySummary
        $summary | Should -Match "AgentA"
        $summary | Should -Match "AgentB"
    }

    It "Includes recent failures" {
        $summary = Get-MemorySummary
        $summary | Should -Match "RecentFailures.*TestX.Fails"
    }

    It "Includes fragile files" {
        $summary = Get-MemorySummary
        $summary | Should -Match "FragileFiles.*AgentA"
    }

    It "Includes known fixes for current failures" {
        $summary = Get-MemorySummary
        $summary | Should -Match "KnownFix.*null check"
    }

    It "Includes already tried approaches" {
        $summary = Get-MemorySummary
        $summary | Should -Match "AlreadyTried.*Fix mocks"
    }

    It "Includes recently changed files" {
        $summary = Get-MemorySummary
        $summary | Should -Match "RecentlyChanged.*AgentA"
    }
}

Describe "Update-Heuristics - Enhanced" {
    BeforeEach {
        $h = @{ coFailures = @{}; fragileFiles = @(); flakyTests = @(); knownFixes = @{}; failureFreq = @{}; fixPatterns = @() }
        Write-MemoryFile "heuristics.json" $h
    }

    It "Tracks failure frequency per file" {
        Update-Heuristics -FailedFiles @("A.ps1")
        Update-Heuristics -FailedFiles @("A.ps1")
        Update-Heuristics -FailedFiles @("A.ps1")

        $h = Read-MemoryFile "heuristics.json"
        [int]$h.failureFreq."A.ps1" | Should -Be 3
    }

    It "Tracks failure frequency per test" {
        Update-Heuristics -FailedTests @("Test.One")
        Update-Heuristics -FailedTests @("Test.One")

        $h = Read-MemoryFile "heuristics.json"
        [int]$h.failureFreq."Test.One" | Should -Be 2
    }

    It "Records fix patterns with success flag" {
        Update-Heuristics -FailedTests @("Test.X") -FixDescription "Added retry" -FixSucceeded $true

        $h = Read-MemoryFile "heuristics.json"
        $h.fixPatterns.Count | Should -Be 1
        $h.fixPatterns[0].description | Should -Be "Added retry"
        $h.fixPatterns[0].succeeded | Should -BeTrue
    }

    It "Limits fix patterns to 30" {
        for ($i = 1; $i -le 35; $i++) {
            Update-Heuristics -FailedTests @("T$i") -FixDescription "Fix $i"
        }

        $h = Read-MemoryFile "heuristics.json"
        $h.fixPatterns.Count | Should -BeLessOrEqual 30
    }
}

Describe "Get-SuggestedFix" {
    BeforeAll {
        # Set up heuristics with known patterns
        $h = @{
            coFailures   = @{ "A.ps1|B.ps1" = 3 }
            fragileFiles = @("A.ps1")
            flakyTests   = @("Test.Alpha")
            knownFixes   = @{ "Test.Alpha" = "Reset mock state" }
            failureFreq  = @{ "A.ps1" = 5; "Test.Alpha" = 3 }
            fixPatterns   = @(
                @{ description = "Added null guard"; succeeded = $true; files = @("A.ps1"); tests = @("Test.Alpha"); timestamp = "2026-01-01T00:00:00" }
                @{ description = "Wrong approach"; succeeded = $false; files = @("A.ps1"); tests = @("Test.Alpha"); timestamp = "2026-01-01T00:01:00" }
            )
        }
        Write-MemoryFile "heuristics.json" $h
    }

    It "Returns known fix for exact test match" {
        $result = Get-SuggestedFix -FailedTests @("Test.Alpha")
        $result | Should -Match "Reset mock state"
    }

    It "Returns successful pattern matches" {
        $result = Get-SuggestedFix -FailedTests @("Test.Alpha") -FailedFiles @("A.ps1")
        $result | Should -Match "null guard"
    }

    It "Skips failed pattern matches" {
        $result = Get-SuggestedFix -FailedTests @("Test.Alpha") -FailedFiles @("A.ps1")
        $result | Should -Not -Match "Wrong approach"
    }

    It "Returns co-failure predictions" {
        $result = Get-SuggestedFix -FailedFiles @("A.ps1")
        $result | Should -Match "B.ps1"
    }

    It "Returns null when no match" {
        $result = Get-SuggestedFix -FailedTests @("Test.Unknown")
        $result | Should -BeNullOrEmpty
    }
}

Describe "Update-GitMemory" {
    It "Captures current branch" {
        $git = Update-GitMemory $PSScriptRoot/..

        $git.branch | Should -Not -BeNullOrEmpty
    }

    It "Captures recent commits" {
        $git = Update-GitMemory $PSScriptRoot/..

        $git.recentCommits.Count | Should -BeGreaterThan 0
        $git.recentCommits[0].hash | Should -Not -BeNullOrEmpty
        $git.recentCommits[0].message | Should -Not -BeNullOrEmpty
    }

    It "Captures uncommitted changes" {
        $git = Update-GitMemory $PSScriptRoot/..

        # There should be uncommitted changes in the repo during tests
        $git.uncommitted | Should -Not -BeNullOrEmpty
    }

    It "Persists to git-state.json" {
        Update-GitMemory $PSScriptRoot/.. | Out-Null

        $loaded = Read-MemoryFile "git-state.json"
        $loaded.branch | Should -Not -BeNullOrEmpty
    }
}

Describe "Compress-Memory" {
    BeforeAll {
        # Set up data that needs compaction
        $h = @{
            coFailures   = @{}
            fragileFiles = @()
            flakyTests   = @()
            knownFixes   = @{}
            failureFreq  = @{}
            fixPatterns   = @()
        }
        # Add lots of failure freq entries
        for ($i = 1; $i -le 50; $i++) {
            $h.failureFreq["entry$i"] = $i
        }
        # Add many fix patterns
        for ($i = 1; $i -le 25; $i++) {
            $h.fixPatterns += @{ description = "Fix $i"; succeeded = $true; files = @(); tests = @(); timestamp = "2026-01-01" }
        }
        Write-MemoryFile "heuristics.json" $h

        # Set up code-intel with excess data
        $intel = @{
            callGraph = @{}; testToCodeMap = @{}; failingTestToCode = @{}
            recentlyChanged = @(1..30 | ForEach-Object { "file$_.ps1" })
        }
        Write-MemoryFile "code-intel.json" $intel
    }

    It "Decays failure frequencies" {
        Compress-Memory | Out-Null

        $h = Read-MemoryFile "heuristics.json"
        # Entry with count 1 should be removed (1-1=0)
        $h.failureFreq.PSObject.Properties["entry1"] | Should -BeNullOrEmpty
        # Entry with count 50 should be decayed to 49
        [int]$h.failureFreq."entry50" | Should -Be 49
    }

    It "Limits failure frequency entries to max" {
        Compress-Memory | Out-Null

        $h = Read-MemoryFile "heuristics.json"
        $h.failureFreq.PSObject.Properties.Count | Should -BeLessOrEqual 40
    }

    It "Limits fix patterns" {
        Compress-Memory | Out-Null

        $h = Read-MemoryFile "heuristics.json"
        $h.fixPatterns.Count | Should -BeLessOrEqual 20
    }

    It "Trims recentlyChanged to 15" {
        Compress-Memory | Out-Null

        $intel = Read-MemoryFile "code-intel.json"
        $intel.recentlyChanged.Count | Should -BeLessOrEqual 15
    }

    It "Returns compaction timestamp" {
        $result = Compress-Memory
        $result.compactedAt | Should -Match "^\d{4}-\d{2}-\d{2}"
    }
}

Describe "Get-MemorySummary - Git Integration" {
    BeforeAll {
        Write-MemoryFile "repo-map.json" @{
            projectType = "powershell"; coreModules = @(@{ name = "Mod1" }); testProjects = @(); entryPoints = @()
        }
        Write-MemoryFile "run-state.json" @{
            iteration = 1; lastFailures = @(); recentFiles = @(); lastDiffSummary = ""; lastAttempts = @(); lastBuildOk = $true; lastTestOk = $true
        }
        Write-MemoryFile "code-intel.json" @{
            callGraph = @{}; testToCodeMap = @{}; recentlyChanged = @(); failingTestToCode = @{}
        }
        Write-MemoryFile "heuristics.json" @{
            coFailures = @{}; fragileFiles = @(); flakyTests = @(); knownFixes = @{}; failureFreq = @{}; fixPatterns = @()
        }
        Write-MemoryFile "git-state.json" @{
            branch = "feature/test"
            recentCommits = @(@{ hash = "abc123"; message = "Add tests"; author = "dev" })
            uncommitted = @(@{ status = "M"; file = "src/main.ps1" })
            lastGoodCommit = "def456"
            diffStat = "2 files changed"
            coChangePatterns = @{}
        }
    }

    It "Includes git branch" {
        $summary = Get-MemorySummary
        $summary | Should -Match "Branch: feature/test"
    }

    It "Includes recent commits" {
        $summary = Get-MemorySummary
        $summary | Should -Match "abc123.*Add tests"
    }

    It "Includes uncommitted changes" {
        $summary = Get-MemorySummary
        $summary | Should -Match "Uncommitted.*main.ps1"
    }

    It "Includes last good commit" {
        $summary = Get-MemorySummary
        $summary | Should -Match "LastGoodCommit: def456"
    }
}

Describe "Initialize-RepoMemory" {
    It "Creates repo-map.json with project type" {
        $map = Initialize-RepoMemory $PSScriptRoot/..

        $map.projectType | Should -Be "powershell"
        $map.coreModules.Count | Should -BeGreaterThan 0
    }

    It "Detects test projects" {
        $map = Initialize-RepoMemory $PSScriptRoot/..

        $map.testProjects.Count | Should -BeGreaterThan 0
    }

    It "Maps module dependencies" {
        $map = Initialize-RepoMemory $PSScriptRoot/..

        $map.dependencies | Should -Not -BeNullOrEmpty
    }
}
