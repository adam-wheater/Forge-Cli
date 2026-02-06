$Global:MemoryRoot = Join-Path $PSScriptRoot ".." "memory"

function Get-MemoryPath {
    param ([string]$FileName)
    Join-Path $Global:MemoryRoot $FileName
}

function Read-MemoryFile {
    param ([string]$FileName)
    $path = Get-MemoryPath $FileName
    if (Test-Path $path) {
        Get-Content $path -Raw | ConvertFrom-Json
    } else {
        $null
    }
}

function Write-MemoryFile {
    param ([string]$FileName, $Data)
    $path = Get-MemoryPath $FileName
    $dir = Split-Path $path -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $Data | ConvertTo-Json -Depth 10 | Out-File $path -Encoding utf8
}

function Initialize-RepoMemory {
    param ([string]$ProjectDir = (Get-Location))

    $repoMap = @{
        solution     = $null
        projectType  = "unknown"
        testProjects = @()
        coreModules  = @()
        entryPoints  = @()
        agentPrompts = @()
        scripts      = @()
        dependencies = @{}
    }

    # Detect solution files
    $sln = Get-ChildItem $ProjectDir -Filter "*.sln" -Recurse -Depth 2 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($sln) { $repoMap.solution = $sln.FullName }

    # Detect project type
    $ps1Files = Get-ChildItem $ProjectDir -Filter "*.ps1" -Recurse -Depth 3 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/](node_modules|\.git|tests)[\\/]' }
    $csFiles = Get-ChildItem $ProjectDir -Filter "*.cs" -Recurse -Depth 5 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/](node_modules|\.git|obj|bin)[\\/]' }

    if ($ps1Files.Count -gt $csFiles.Count) {
        $repoMap.projectType = "powershell"
    } elseif ($csFiles.Count -gt 0) {
        $repoMap.projectType = "dotnet"
    }

    # Map core modules (lib/*.ps1 or src/**/*.cs)
    $libFiles = Get-ChildItem (Join-Path $ProjectDir "lib") -Filter "*.ps1" -ErrorAction SilentlyContinue
    if ($libFiles) {
        $repoMap.coreModules = @($libFiles | ForEach-Object {
            @{ name = $_.BaseName; path = $_.FullName -replace [regex]::Escape($ProjectDir), "." }
        })
    }

    # Map test projects
    $testFiles = Get-ChildItem $ProjectDir -Filter "*.Tests.ps1" -Recurse -Depth 3 -ErrorAction SilentlyContinue
    if ($testFiles) {
        $repoMap.testProjects = @($testFiles | ForEach-Object {
            $_.FullName -replace [regex]::Escape($ProjectDir), "."
        })
    }
    $csprojTests = Get-ChildItem $ProjectDir -Filter "*Tests.csproj" -Recurse -Depth 5 -ErrorAction SilentlyContinue
    if ($csprojTests) {
        $repoMap.testProjects += @($csprojTests | ForEach-Object {
            $_.FullName -replace [regex]::Escape($ProjectDir), "."
        })
    }

    # Map entry points
    $entryNames = @("run.ps1", "Program.cs", "Startup.cs", "Main.cs")
    foreach ($name in $entryNames) {
        $found = Get-ChildItem $ProjectDir -Filter $name -Recurse -Depth 3 -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) {
            $repoMap.entryPoints += ($found.FullName -replace [regex]::Escape($ProjectDir), ".")
        }
    }

    # Map agent prompts
    $promptFiles = Get-ChildItem (Join-Path $ProjectDir "agents") -Filter "*.txt" -ErrorAction SilentlyContinue
    if ($promptFiles) {
        $repoMap.agentPrompts = @($promptFiles | ForEach-Object { $_.BaseName })
    }

    # Map shell scripts
    $shellScripts = Get-ChildItem (Join-Path $ProjectDir "scripts") -Filter "*.sh" -ErrorAction SilentlyContinue
    if ($shellScripts) {
        $repoMap.scripts = @($shellScripts | ForEach-Object { $_.Name })
    }

    # Map dependencies between modules
    $deps = @{}
    foreach ($mod in $libFiles) {
        $content = Get-Content $mod.FullName -Raw -ErrorAction SilentlyContinue
        $dotSources = [regex]::Matches($content, '\.\s+"[^"]*[\\/]([^"\\\/]+\.ps1)"')
        $deps[$mod.BaseName] = @($dotSources | ForEach-Object { $_.Groups[1].Value -replace '\.ps1$', '' })
    }
    $repoMap.dependencies = $deps

    Write-MemoryFile "repo-map.json" $repoMap

    # Build initial code intelligence
    Update-CodeIntel $ProjectDir

    return $repoMap
}

function Update-CodeIntel {
    param ([string]$ProjectDir = (Get-Location))

    $intel = @{
        callGraph         = @{}
        testToCodeMap     = @{}
        recentlyChanged   = @()
        failingTestToCode = @{}
    }

    # Build call graph from PowerShell dot-sources and function calls
    $libDir = Join-Path $ProjectDir "lib"
    if (Test-Path $libDir) {
        $libFiles = Get-ChildItem $libDir -Filter "*.ps1" -ErrorAction SilentlyContinue
        foreach ($f in $libFiles) {
            $content = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
            if (-not $content) { continue }

            # Extract function definitions
            $funcNames = [regex]::Matches($content, 'function\s+([\w-]+)') | ForEach-Object { $_.Groups[1].Value }
            # Extract Verb-Noun style function calls (PowerShell convention)
            $allCalls = [regex]::Matches($content, '\b([A-Z][\w]*-[A-Z][\w]*)\b') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
            $intel.callGraph[$f.BaseName] = @{
                defines = @($funcNames)
                calls   = @($allCalls | Where-Object { $_ -notin $funcNames })
            }
        }
    }

    # Map tests to code
    $testDir = Join-Path $ProjectDir "tests"
    if (Test-Path $testDir) {
        $testFiles = Get-ChildItem $testDir -Filter "*.Tests.ps1" -ErrorAction SilentlyContinue
        foreach ($t in $testFiles) {
            $moduleName = $t.BaseName -replace '\.Tests$', ''
            $modulePath = Join-Path $libDir "$moduleName.ps1"
            if (Test-Path $modulePath) {
                $intel.testToCodeMap[$t.BaseName] = @("lib/$moduleName.ps1")
            }
        }
    }

    # Get recently changed files from git
    try {
        $gitChanges = git log --name-only --pretty=format: -10 2>$null | Where-Object { $_ -ne '' } | Select-Object -Unique -First 20
        if ($gitChanges) {
            $intel.recentlyChanged = @($gitChanges)
        }
    } catch { }

    Write-MemoryFile "code-intel.json" $intel
    return $intel
}

function Save-RunState {
    param (
        [int]$Iteration = 0,
        [string[]]$Failures = @(),
        [string[]]$RecentFiles = @(),
        [string]$DiffSummary = "",
        [string[]]$Attempts = @(),
        [bool]$BuildOk = $true,
        [bool]$TestOk = $true
    )

    $state = @{
        iteration       = $Iteration
        lastFailures    = @($Failures)
        recentFiles     = @($RecentFiles)
        lastDiffSummary = $DiffSummary
        lastAttempts    = @($Attempts)
        lastBuildOk     = $BuildOk
        lastTestOk      = $TestOk
    }

    Write-MemoryFile "run-state.json" $state
    return $state
}

function Update-Heuristics {
    param (
        [string[]]$FailedFiles = @(),
        [string[]]$FailedTests = @(),
        [string]$FixDescription = "",
        [bool]$FixSucceeded = $false
    )

    $h = Read-MemoryFile "heuristics.json"
    if (-not $h) {
        $h = [PSCustomObject]@{
            coFailures     = [PSCustomObject]@{}
            fragileFiles   = @()
            flakyTests     = @()
            knownFixes     = [PSCustomObject]@{}
            failureFreq    = [PSCustomObject]@{}
            fixPatterns     = @()
        }
    }

    # Ensure all properties exist (upgrade from older schema)
    if (-not ($h.PSObject.Properties['failureFreq'])) {
        $h | Add-Member -NotePropertyName 'failureFreq' -NotePropertyValue ([PSCustomObject]@{}) -Force
    }
    if (-not ($h.PSObject.Properties['fixPatterns'])) {
        $h | Add-Member -NotePropertyName 'fixPatterns' -NotePropertyValue @() -Force
    }

    # Track co-failures: files that fail together
    if ($FailedFiles.Count -ge 2) {
        for ($i = 0; $i -lt $FailedFiles.Count; $i++) {
            for ($j = $i + 1; $j -lt $FailedFiles.Count; $j++) {
                $key = ($FailedFiles[$i], $FailedFiles[$j] | Sort-Object) -join "|"
                $current = 0
                if ($h.coFailures.PSObject.Properties[$key]) {
                    $current = [int]$h.coFailures.$key
                }
                $h.coFailures | Add-Member -NotePropertyName $key -NotePropertyValue ($current + 1) -Force
            }
        }
    }

    # Track failure frequency per file and test
    foreach ($f in $FailedFiles) {
        $current = 0
        if ($h.failureFreq.PSObject.Properties[$f]) {
            $current = [int]$h.failureFreq.$f
        }
        $h.failureFreq | Add-Member -NotePropertyName $f -NotePropertyValue ($current + 1) -Force
    }
    foreach ($t in $FailedTests) {
        $current = 0
        if ($h.failureFreq.PSObject.Properties[$t]) {
            $current = [int]$h.failureFreq.$t
        }
        $h.failureFreq | Add-Member -NotePropertyName $t -NotePropertyValue ($current + 1) -Force
    }

    # Track fragile files (failed more than once)
    $fragile = @($h.fragileFiles)
    foreach ($f in $FailedFiles) {
        if ($f -notin $fragile) { $fragile += $f }
    }
    $h.fragileFiles = @($fragile | Select-Object -Last 20)

    # Track flaky tests
    $flaky = @($h.flakyTests)
    foreach ($t in $FailedTests) {
        if ($t -notin $flaky) { $flaky += $t }
    }
    $h.flakyTests = @($flaky | Select-Object -Last 20)

    # Track known fixes
    if ($FixDescription -and $FailedTests.Count -gt 0) {
        $testKey = $FailedTests[0]
        $h.knownFixes | Add-Member -NotePropertyName $testKey -NotePropertyValue $FixDescription -Force
    }

    # Track fix patterns (what was tried, whether it worked)
    if ($FixDescription) {
        $pattern = @{
            description = $FixDescription
            succeeded   = $FixSucceeded
            files       = @($FailedFiles | Select-Object -First 5)
            tests       = @($FailedTests | Select-Object -First 5)
            timestamp   = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
        }
        $patterns = @($h.fixPatterns) + @($pattern)
        $h.fixPatterns = @($patterns | Select-Object -Last 30)
    }

    Write-MemoryFile "heuristics.json" $h
    return $h
}

# ============================================================
# GIT-AWARE MEMORY
# ============================================================

function Update-GitMemory {
    param ([string]$ProjectDir = (Get-Location))

    $git = @{
        branch           = ""
        recentCommits    = @()
        uncommitted      = @()
        lastGoodCommit   = ""
        diffStat         = ""
        coChangePatterns = @{}
    }

    try {
        # Current branch
        $git.branch = (git -C $ProjectDir rev-parse --abbrev-ref HEAD 2>$null)

        # Recent commits (last 15)
        $logLines = git -C $ProjectDir log --oneline --format="%h|%s|%an" -15 2>$null
        if ($logLines) {
            $git.recentCommits = @($logLines | ForEach-Object {
                $parts = $_ -split '\|', 3
                if ($parts.Count -ge 2) {
                    @{ hash = $parts[0]; message = $parts[1]; author = if ($parts.Count -ge 3) { $parts[2] } else { "" } }
                }
            } | Where-Object { $_ })
        }

        # Uncommitted changes
        $statusLines = git -C $ProjectDir status --porcelain 2>$null
        if ($statusLines) {
            $git.uncommitted = @($statusLines | ForEach-Object {
                $status = $_.Substring(0, 2).Trim()
                $file = $_.Substring(3).Trim()
                @{ status = $status; file = $file }
            } | Select-Object -First 20)
        }

        # Last known-good commit (last commit where tests likely passed — look for success markers)
        $successCommit = git -C $ProjectDir log --oneline --grep="SUCCESS\|passed\|✅" -1 --format="%h" 2>$null
        if ($successCommit) {
            $git.lastGoodCommit = $successCommit
        }

        # Diff stat from HEAD
        $git.diffStat = (git -C $ProjectDir diff --stat 2>$null | Select-Object -Last 1)

        # Co-change patterns: files that are committed together frequently
        $coChanges = @{}
        $commitFiles = git -C $ProjectDir log --name-only --pretty=format:"COMMIT" -20 2>$null
        if ($commitFiles) {
            $currentGroup = @()
            foreach ($line in $commitFiles) {
                if ($line -eq "COMMIT" -or $line -eq "") {
                    if ($currentGroup.Count -ge 2) {
                        for ($i = 0; $i -lt [Math]::Min($currentGroup.Count, 5); $i++) {
                            for ($j = $i + 1; $j -lt [Math]::Min($currentGroup.Count, 5); $j++) {
                                $key = ($currentGroup[$i], $currentGroup[$j] | Sort-Object) -join "|"
                                if ($coChanges.ContainsKey($key)) {
                                    $coChanges[$key]++
                                } else {
                                    $coChanges[$key] = 1
                                }
                            }
                        }
                    }
                    $currentGroup = @()
                } else {
                    $currentGroup += $line
                }
            }
        }
        # Keep only pairs that co-changed 2+ times
        $filtered = @{}
        foreach ($k in $coChanges.Keys) {
            if ($coChanges[$k] -ge 2) { $filtered[$k] = $coChanges[$k] }
        }
        $git.coChangePatterns = $filtered

    } catch { }

    Write-MemoryFile "git-state.json" $git
    return $git
}

function Get-BlameForFile {
    param (
        [string]$FilePath,
        [int[]]$Lines = @(),
        [string]$ProjectDir = (Get-Location)
    )

    $results = @()
    try {
        if ($Lines.Count -gt 0) {
            foreach ($line in $Lines | Select-Object -First 5) {
                $blame = git -C $ProjectDir blame -L "$line,$line" --porcelain $FilePath 2>$null
                if ($blame) {
                    $hash = ($blame | Select-Object -First 1) -split ' ' | Select-Object -First 1
                    $author = ($blame | Where-Object { $_ -match '^author (.+)' }) -replace '^author ', ''
                    $time = ($blame | Where-Object { $_ -match '^author-time (.+)' }) -replace '^author-time ', ''
                    $results += @{ line = $line; hash = $hash; author = $author; time = $time }
                }
            }
        } else {
            # Summary blame: who touched this file most recently
            $blameAll = git -C $ProjectDir log -1 --format="%h|%an|%ar" -- $FilePath 2>$null
            if ($blameAll) {
                $parts = $blameAll -split '\|', 3
                $results += @{ hash = $parts[0]; author = $parts[1]; when = $parts[2] }
            }
        }
    } catch { }

    return $results
}

# ============================================================
# AUTOMATIC MEMORY COMPACTION
# ============================================================

function Compress-Memory {
    param ([int]$MaxCoFailures = 30, [int]$MaxFixPatterns = 20, [int]$MaxFreqEntries = 40)

    # --- Compact heuristics ---
    $h = Read-MemoryFile "heuristics.json"
    if ($h) {
        # Decay co-failure counts (halve anything > 4, remove zeroes)
        if ($h.coFailures -and $h.coFailures.PSObject.Properties.Count -gt 0) {
            $toRemove = @()
            foreach ($prop in $h.coFailures.PSObject.Properties) {
                $val = [int]$prop.Value
                if ($val -gt 4) {
                    $h.coFailures | Add-Member -NotePropertyName $prop.Name -NotePropertyValue ([Math]::Floor($val / 2)) -Force
                } elseif ($val -le 0) {
                    $toRemove += $prop.Name
                }
            }
            foreach ($name in $toRemove) {
                $h.coFailures.PSObject.Properties.Remove($name)
            }
            # Prune to max size — keep highest counts
            if ($h.coFailures.PSObject.Properties.Count -gt $MaxCoFailures) {
                $sorted = $h.coFailures.PSObject.Properties | Sort-Object Value -Descending | Select-Object -First $MaxCoFailures
                $newCoFailures = [PSCustomObject]@{}
                foreach ($p in $sorted) {
                    $newCoFailures | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
                }
                $h.coFailures = $newCoFailures
            }
        }

        # Decay failure frequencies (subtract 1 from everything, remove zeroes)
        if ($h.PSObject.Properties['failureFreq'] -and $h.failureFreq.PSObject.Properties.Count -gt 0) {
            $toRemove = @()
            foreach ($prop in $h.failureFreq.PSObject.Properties) {
                $val = [int]$prop.Value - 1
                if ($val -le 0) {
                    $toRemove += $prop.Name
                } else {
                    $h.failureFreq | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $val -Force
                }
            }
            foreach ($name in $toRemove) {
                $h.failureFreq.PSObject.Properties.Remove($name)
            }
            # Prune to max
            if ($h.failureFreq.PSObject.Properties.Count -gt $MaxFreqEntries) {
                $sorted = $h.failureFreq.PSObject.Properties | Sort-Object Value -Descending | Select-Object -First $MaxFreqEntries
                $newFreq = [PSCustomObject]@{}
                foreach ($p in $sorted) {
                    $newFreq | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
                }
                $h.failureFreq = $newFreq
            }
        }

        # Trim fix patterns to max
        if ($h.PSObject.Properties['fixPatterns'] -and $h.fixPatterns.Count -gt $MaxFixPatterns) {
            $h.fixPatterns = @($h.fixPatterns | Select-Object -Last $MaxFixPatterns)
        }

        # Trim known fixes to 20 most recent
        if ($h.knownFixes -and $h.knownFixes.PSObject.Properties.Count -gt 20) {
            $keep = $h.knownFixes.PSObject.Properties | Select-Object -Last 20
            $newFixes = [PSCustomObject]@{}
            foreach ($p in $keep) {
                $newFixes | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
            }
            $h.knownFixes = $newFixes
        }

        Write-MemoryFile "heuristics.json" $h
    }

    # --- Compact code-intel ---
    $intel = Read-MemoryFile "code-intel.json"
    if ($intel) {
        # Trim recentlyChanged to 15
        if ($intel.recentlyChanged -and $intel.recentlyChanged.Count -gt 15) {
            $intel.recentlyChanged = @($intel.recentlyChanged | Select-Object -First 15)
        }

        # Remove call graph entries for modules that no longer exist
        if ($intel.callGraph) {
            $libDir = Join-Path (Split-Path $Global:MemoryRoot -Parent) "lib"
            if (Test-Path $libDir) {
                $existingModules = @(Get-ChildItem $libDir -Filter "*.ps1" -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName })
                $toRemove = @()
                foreach ($prop in $intel.callGraph.PSObject.Properties) {
                    if ($prop.Name -notin $existingModules) { $toRemove += $prop.Name }
                }
                foreach ($name in $toRemove) {
                    $intel.callGraph.PSObject.Properties.Remove($name)
                }
            }
        }

        Write-MemoryFile "code-intel.json" $intel
    }

    # --- Compact git state ---
    $git = Read-MemoryFile "git-state.json"
    if ($git) {
        if ($git.recentCommits -and $git.recentCommits.Count -gt 10) {
            $git.recentCommits = @($git.recentCommits | Select-Object -First 10)
        }
        if ($git.uncommitted -and $git.uncommitted.Count -gt 15) {
            $git.uncommitted = @($git.uncommitted | Select-Object -First 15)
        }
        # Prune co-change patterns to top 20
        if ($git.coChangePatterns -and $git.coChangePatterns.PSObject.Properties.Count -gt 20) {
            $sorted = $git.coChangePatterns.PSObject.Properties | Sort-Object Value -Descending | Select-Object -First 20
            $newPatterns = [PSCustomObject]@{}
            foreach ($p in $sorted) {
                $newPatterns | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
            }
            $git.coChangePatterns = $newPatterns
        }
        Write-MemoryFile "git-state.json" $git
    }

    return @{ compactedAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss") }
}

function Get-SuggestedFix {
    param ([string[]]$FailedTests = @(), [string[]]$FailedFiles = @())

    $h = Read-MemoryFile "heuristics.json"
    if (-not $h) { return $null }

    $suggestions = @()

    # Check known fixes for exact test match
    if ($h.knownFixes) {
        foreach ($test in $FailedTests) {
            if ($h.knownFixes.PSObject.Properties[$test]) {
                $suggestions += "KnownFix[$test]: $($h.knownFixes.$test)"
            }
        }
    }

    # Check fix patterns for similar failures
    if ($h.PSObject.Properties['fixPatterns'] -and $h.fixPatterns.Count -gt 0) {
        foreach ($pattern in $h.fixPatterns) {
            if (-not $pattern.succeeded) { continue }
            $matchScore = 0
            foreach ($f in $FailedFiles) {
                if ($pattern.files -contains $f) { $matchScore++ }
            }
            foreach ($t in $FailedTests) {
                if ($pattern.tests -contains $t) { $matchScore += 2 }
            }
            if ($matchScore -gt 0) {
                $suggestions += "PatternMatch(score=$matchScore): $($pattern.description)"
            }
        }
    }

    # Check co-failure predictions
    if ($h.coFailures -and $FailedFiles.Count -gt 0) {
        foreach ($file in $FailedFiles) {
            foreach ($prop in $h.coFailures.PSObject.Properties) {
                $pair = $prop.Name -split '\|'
                if ($pair -contains $file) {
                    $other = $pair | Where-Object { $_ -ne $file } | Select-Object -First 1
                    if ($other -and $other -notin $FailedFiles) {
                        $suggestions += "CoFailure: $file often fails with $other (count=$($prop.Value)) — check $other too"
                    }
                }
            }
        }
    }

    if ($suggestions.Count -gt 0) {
        return ($suggestions | Select-Object -First 5) -join "`n"
    }
    return $null
}

function Get-MemorySummary {
    param ([string[]]$Focus = @())

    $repoMap = Read-MemoryFile "repo-map.json"
    $intel = Read-MemoryFile "code-intel.json"
    $run = Read-MemoryFile "run-state.json"
    $heuristics = Read-MemoryFile "heuristics.json"
    $git = Read-MemoryFile "git-state.json"

    $lines = @()
    $lines += "REPO_MEMORY:"

    # Repo map summary
    if ($repoMap) {
        $lines += "Project: $($repoMap.projectType)"
        if ($repoMap.solution) { $lines += "Solution: $($repoMap.solution)" }
        if ($repoMap.coreModules) {
            $moduleNames = @($repoMap.coreModules | ForEach-Object { $_.name }) -join ", "
            $lines += "Modules: $moduleNames"
        }
        if ($repoMap.testProjects) {
            $lines += "Tests: $(($repoMap.testProjects | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')"
        }
        if ($repoMap.entryPoints) {
            $lines += "EntryPoints: $(($repoMap.entryPoints | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')"
        }
    }

    # Git state summary
    if ($git) {
        if ($git.branch) { $lines += "Branch: $($git.branch)" }
        if ($git.recentCommits -and $git.recentCommits.Count -gt 0) {
            $commitSummary = ($git.recentCommits | Select-Object -First 3 | ForEach-Object { "$($_.hash) $($_.message)" }) -join "; "
            $lines += "RecentCommits: $commitSummary"
        }
        if ($git.uncommitted -and $git.uncommitted.Count -gt 0) {
            $uncommittedFiles = ($git.uncommitted | Select-Object -First 8 | ForEach-Object { "$($_.status) $($_.file)" }) -join ", "
            $lines += "Uncommitted: $uncommittedFiles"
        }
        if ($git.diffStat) { $lines += "DiffStat: $($git.diffStat)" }
        if ($git.lastGoodCommit) { $lines += "LastGoodCommit: $($git.lastGoodCommit)" }
        # Include co-change patterns relevant to focus files
        if ($Focus.Count -gt 0 -and $git.coChangePatterns) {
            foreach ($file in $Focus) {
                foreach ($prop in $git.coChangePatterns.PSObject.Properties) {
                    $pair = $prop.Name -split '\|'
                    if ($pair -contains $file) {
                        $other = $pair | Where-Object { $_ -ne $file } | Select-Object -First 1
                        if ($other) { $lines += "CoChange: $file <-> $other ($($prop.Value)x)" }
                    }
                }
            }
        }
    }

    # Run state summary
    if ($run) {
        if ($run.lastFailures -and $run.lastFailures.Count -gt 0) {
            $lines += "RecentFailures: $($run.lastFailures -join ', ')"
        }
        if ($run.recentFiles -and $run.recentFiles.Count -gt 0) {
            $lines += "RecentFiles: $(($run.recentFiles | Select-Object -First 10) -join ', ')"
        }
        if ($run.lastDiffSummary) {
            $lines += "LastDiff: $($run.lastDiffSummary)"
        }
        if ($run.lastAttempts -and $run.lastAttempts.Count -gt 0) {
            $lines += "AlreadyTried: $($run.lastAttempts -join ', ')"
        }
        if (-not $run.lastBuildOk) { $lines += "WARNING: Last build FAILED" }
        if (-not $run.lastTestOk) { $lines += "WARNING: Last tests FAILED" }
    }

    # Code intelligence slice (only relevant parts)
    if ($intel) {
        if ($intel.recentlyChanged -and $intel.recentlyChanged.Count -gt 0) {
            $lines += "RecentlyChanged: $(($intel.recentlyChanged | Select-Object -First 10) -join ', ')"
        }

        # If there are focus files, include their call graph
        if ($Focus.Count -gt 0 -and $intel.callGraph) {
            foreach ($f in $Focus) {
                $baseName = [System.IO.Path]::GetFileNameWithoutExtension($f)
                if ($intel.callGraph.PSObject.Properties[$baseName]) {
                    $entry = $intel.callGraph.$baseName
                    if ($entry.defines) { $lines += "Functions[$baseName]: $($entry.defines -join ', ')" }
                    if ($entry.calls) { $lines += "Calls[$baseName]: $($entry.calls -join ', ')" }
                }
            }
        }

        # Include failing test mapping
        if ($intel.failingTestToCode) {
            $props = $intel.failingTestToCode.PSObject.Properties
            if ($props.Count -gt 0) {
                foreach ($p in $props) {
                    $lines += "FailMap: $($p.Name) -> $($p.Value -join ', ')"
                }
            }
        }
    }

    # Heuristics summary
    if ($heuristics) {
        if ($heuristics.fragileFiles -and $heuristics.fragileFiles.Count -gt 0) {
            $lines += "FragileFiles: $(($heuristics.fragileFiles | Select-Object -Last 5) -join ', ')"
        }
        if ($heuristics.flakyTests -and $heuristics.flakyTests.Count -gt 0) {
            $lines += "FlakyTests: $(($heuristics.flakyTests | Select-Object -Last 5) -join ', ')"
        }

        # High-frequency failures (most problematic files/tests)
        if ($heuristics.PSObject.Properties['failureFreq'] -and $heuristics.failureFreq.PSObject.Properties.Count -gt 0) {
            $topFailures = $heuristics.failureFreq.PSObject.Properties |
                Sort-Object Value -Descending | Select-Object -First 3
            if ($topFailures) {
                $freqSummary = ($topFailures | ForEach-Object { "$($_.Name)($($_.Value)x)" }) -join ", "
                $lines += "MostFragile: $freqSummary"
            }
        }

        # Include known fixes relevant to current failures
        if ($run -and $run.lastFailures -and $heuristics.knownFixes) {
            foreach ($failure in $run.lastFailures) {
                if ($heuristics.knownFixes.PSObject.Properties[$failure]) {
                    $lines += "KnownFix[$failure]: $($heuristics.knownFixes.$failure)"
                }
            }
        }

        # Include suggested fixes from pattern matching
        if ($run -and $run.lastFailures) {
            $suggestion = Get-SuggestedFix -FailedTests $run.lastFailures -FailedFiles @($run.recentFiles)
            if ($suggestion) {
                $lines += "SuggestedFix: $suggestion"
            }
        }
    }

    $lines -join "`n"
}
