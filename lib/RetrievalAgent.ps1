# RetrievalAgent.ps1 — Unified context assembly service for the orchestrated agent framework.
# Wraps Embeddings.ps1, RepoMemory.ps1, and CSharpAnalyser.ps1 into a single retrieval pipeline
# that assembles task-appropriate context for worker agents.

. "$PSScriptRoot/Embeddings.ps1"
. "$PSScriptRoot/RepoMemory.ps1"
. "$PSScriptRoot/CSharpAnalyser.ps1"
. "$PSScriptRoot/ImportGraph.ps1"
. "$PSScriptRoot/CallGraph.ps1"

# Retrieval intensity profiles per task type
$script:RetrievalProfiles = @{
    investigate = @{ SemanticTopK = 15; MemoryLevel = "low";    StructuralLevel = "medium" }
    modify      = @{ SemanticTopK = 10; MemoryLevel = "high";   StructuralLevel = "high"   }
    test        = @{ SemanticTopK = 5;  MemoryLevel = "high";   StructuralLevel = "low"    }
    review      = @{ SemanticTopK = 5;  MemoryLevel = "low";    StructuralLevel = "medium" }
    analyze     = @{ SemanticTopK = 15; MemoryLevel = "medium"; StructuralLevel = "high"   }
}

function Invoke-ContextRetrieval {
    <#
    .SYNOPSIS
        Assembles context for a task by combining semantic, memory, and structural retrieval.
    #>
    param (
        [Parameter(Mandatory)][hashtable]$Task,
        [int]$MaxContextTokens = 8000,
        [string[]]$FocusFiles = @()
    )

    $profile = $script:RetrievalProfiles[$Task.type]
    if (-not $profile) {
        $profile = $script:RetrievalProfiles["investigate"]
    }

    # 1. Semantic retrieval — find code relevant to the task instruction
    $semanticCtx = ""
    if ($Global:EmbeddingCache -and $Global:EmbeddingCache.Count -gt 0) {
        $semanticCtx = Invoke-SemanticRetrieval -Query $Task.instruction -TopK $profile.SemanticTopK
    } else {
        # Fallback: regex-based file search
        $semanticCtx = Invoke-FallbackRetrieval -Query $Task.instruction
    }

    # 2. Memory retrieval — heuristics, known fixes, repo state
    $memoryCtx = Invoke-MemoryRetrieval -Level $profile.MemoryLevel -FocusFiles $FocusFiles

    # 3. Structural retrieval — symbols, imports, dependencies for relevant files
    $structuralCtx = ""
    if ($profile.StructuralLevel -ne "low") {
        $filesToAnalyze = Get-FilesFromContext -SemanticContext $semanticCtx -FocusFiles $FocusFiles
        $structuralCtx = Invoke-StructuralRetrieval -Files $filesToAnalyze -Level $profile.StructuralLevel
    }

    # 4. Prior task results (from completed tasks in the same orchestration)
    $priorResults = Get-PriorTaskResults -CurrentTask $Task

    # 5. Assemble into final context
    $context = Build-TaskContext `
        -Task $Task `
        -SemanticContext $semanticCtx `
        -MemoryContext $memoryCtx `
        -StructuralContext $structuralCtx `
        -PriorResults $priorResults `
        -MaxTokens $MaxContextTokens

    return $context
}

function Invoke-SemanticRetrieval {
    <#
    .SYNOPSIS
        Retrieves semantically similar code chunks for a query using the embedding index.
    #>
    param (
        [Parameter(Mandatory)][string]$Query,
        [int]$TopK = 10
    )

    try {
        $results = Invoke-SemanticSearch -Query $Query -TopK $TopK
        if (-not $results -or $results.Count -eq 0) {
            return ""
        }

        $lines = @("RELEVANT_CODE:")
        foreach ($result in $results) {
            $file = if ($result.File) { $result.File } elseif ($result.PSObject.Properties['file']) { $result.file } else { "unknown" }
            $content = if ($result.Content) { $result.Content } elseif ($result.PSObject.Properties['content']) { $result.content } else { "" }
            $score = if ($result.Similarity) { $result.Similarity } elseif ($result.PSObject.Properties['similarity']) { $result.similarity } else { 0 }

            $lines += "--- $file (score: $([math]::Round($score, 3))) ---"
            $lines += $content
            $lines += ""
        }
        return ($lines -join "`n")
    } catch {
        Write-Warning "Semantic retrieval failed: $($_.Exception.Message)"
        return ""
    }
}

function Invoke-FallbackRetrieval {
    <#
    .SYNOPSIS
        Falls back to regex-based file search when embeddings are unavailable.
    #>
    param (
        [Parameter(Mandatory)][string]$Query
    )

    try {
        # Extract keywords from query (simple word extraction)
        $keywords = $Query -split '\s+' | Where-Object { $_.Length -gt 3 } | Select-Object -First 5
        $lines = @("RELEVANT_FILES:")

        foreach ($keyword in $keywords) {
            $results = Search-Files -Pattern $keyword
            if ($results) {
                foreach ($file in ($results | Select-Object -First 3)) {
                    $lines += "  - $file"
                }
            }
        }

        if ($lines.Count -le 1) { return "" }
        return ($lines -join "`n")
    } catch {
        return ""
    }
}

function Invoke-MemoryRetrieval {
    <#
    .SYNOPSIS
        Retrieves repository memory context at the specified intensity level.
    #>
    param (
        [ValidateSet("low", "medium", "high")][string]$Level = "medium",
        [string[]]$FocusFiles = @()
    )

    $lines = @()

    # Always include budget status
    $totalTokens = Get-TotalTokens
    $cost = Get-CurrentCostGBP
    $lines += "BUDGET_REMAINING:"
    $lines += "  Tokens: $totalTokens / $($Global:MAX_TOTAL_TOKENS)"
    $lines += "  Cost: $([math]::Round($cost, 4)) GBP / $($Global:MAX_COST_GBP) GBP"
    $lines += ""

    switch ($Level) {
        "low" {
            # Minimal: just repo structure overview
            $repoMap = Read-MemoryFile "repo-map.json"
            if ($repoMap) {
                $lines += "REPO_STRUCTURE:"
                if ($repoMap.solutionFiles) { $lines += "  Solutions: $($repoMap.solutionFiles -join ', ')" }
                if ($repoMap.testProjects)  { $lines += "  Test projects: $($repoMap.testProjects -join ', ')" }
                $lines += ""
            }
        }
        "medium" {
            # Moderate: repo structure + recent state
            $summary = Get-MemorySummary -Focus $FocusFiles
            if ($summary) {
                # Truncate to ~2000 chars for medium level
                if ($summary.Length -gt 2000) {
                    $summary = $summary.Substring(0, 2000) + "`n... (truncated)"
                }
                $lines += $summary
            }
        }
        "high" {
            # Full: complete memory summary + suggested fixes
            $summary = Get-MemorySummary -Focus $FocusFiles
            if ($summary) { $lines += $summary }

            # Add suggested fixes if available
            $suggestions = Get-SuggestedFix -FailedFiles $FocusFiles
            if ($suggestions) {
                $lines += ""
                $lines += "SUGGESTED_FIXES:"
                foreach ($s in $suggestions) {
                    $lines += "  - $($s.description): $($s.suggestion)"
                }
            }
        }
    }

    return ($lines -join "`n")
}

function Invoke-StructuralRetrieval {
    <#
    .SYNOPSIS
        Retrieves structural information (symbols, imports, dependencies) for specified files.
    #>
    param (
        [string[]]$Files = @(),
        [ValidateSet("medium", "high")][string]$Level = "medium"
    )

    if (-not $Files -or $Files.Count -eq 0) { return "" }

    $lines = @("CODE_STRUCTURE:")

    foreach ($file in ($Files | Select-Object -First 10)) {
        if (-not (Test-Path $file)) { continue }

        $lines += "--- $file ---"

        # Symbols (always included at medium+)
        try {
            $symbols = Get-CSharpSymbols -FilePath $file
            if ($symbols) {
                $lines += "  Symbols: $symbols"
            }
        } catch { }

        # Imports
        try {
            $imports = Get-Imports -FilePath $file
            if ($imports) {
                $lines += "  Imports: $($imports -join ', ')"
            }
        } catch { }

        if ($Level -eq "high") {
            # Constructor dependencies
            try {
                $deps = Get-ConstructorDependencies -FilePath $file
                if ($deps) {
                    $lines += "  Dependencies: $($deps -join ', ')"
                }
            } catch { }

            # Interface (if it's a class that implements interfaces)
            try {
                $iface = Get-CSharpInterface -FilePath $file
                if ($iface) {
                    $lines += "  Interface: $iface"
                }
            } catch { }
        }

        $lines += ""
    }

    return ($lines -join "`n")
}

function Get-FilesFromContext {
    <#
    .SYNOPSIS
        Extracts file paths from semantic context results and focus files.
    #>
    param (
        [string]$SemanticContext = "",
        [string[]]$FocusFiles = @()
    )

    $files = @()

    # Add focus files
    $files += $FocusFiles

    # Extract file paths from semantic context (lines matching "--- path/to/file.cs ---")
    if ($SemanticContext) {
        $matches = [regex]::Matches($SemanticContext, '--- (.+?\.\w+) ')
        foreach ($m in $matches) {
            $files += $m.Groups[1].Value
        }
    }

    return ($files | Select-Object -Unique | Where-Object { $_ })
}

function Get-PriorTaskResults {
    <#
    .SYNOPSIS
        Collects results from previously completed tasks in the current orchestration.
    #>
    param (
        [Parameter(Mandatory)][hashtable]$CurrentTask
    )

    if (-not $Global:CompletedTasks -or $Global:CompletedTasks.Count -eq 0) {
        return ""
    }

    # Only include results from tasks this task depends on
    $deps = $CurrentTask.dependencies
    if (-not $deps -or $deps.Count -eq 0) { return "" }

    $lines = @("PRIOR_RESULTS:")
    foreach ($completed in $Global:CompletedTasks) {
        if ($deps -contains $completed.id) {
            $resultPreview = if ($completed.result -and $completed.result.Length -gt 1500) {
                $completed.result.Substring(0, 1500) + "`n... (truncated)"
            } else {
                $completed.result
            }
            $lines += "--- Task $($completed.id) ($($completed.type)): $($completed.instruction) ---"
            $lines += $resultPreview
            $lines += ""
        }
    }

    if ($lines.Count -le 1) { return "" }
    return ($lines -join "`n")
}

function Build-TaskContext {
    <#
    .SYNOPSIS
        Assembles all context pieces into a single string, trimmed to token budget.
    #>
    param (
        [Parameter(Mandatory)][hashtable]$Task,
        [string]$SemanticContext = "",
        [string]$MemoryContext = "",
        [string]$StructuralContext = "",
        [string]$PriorResults = "",
        [int]$MaxTokens = 8000
    )

    $maxChars = $MaxTokens * 4  # ~4 chars per token estimate

    $sections = @()

    # Task instruction is always first (never trimmed)
    $sections += "TASK_INSTRUCTION:"
    $sections += $Task.instruction
    $sections += ""

    # Memory context (budget info + repo knowledge)
    if ($MemoryContext) {
        $sections += $MemoryContext
        $sections += ""
    }

    # Prior results from dependency tasks
    if ($PriorResults) {
        $sections += $PriorResults
        $sections += ""
    }

    # Semantic context (retrieved code)
    if ($SemanticContext) {
        $sections += $SemanticContext
        $sections += ""
    }

    # Structural context
    if ($StructuralContext) {
        $sections += $StructuralContext
        $sections += ""
    }

    $assembled = $sections -join "`n"

    # Trim to budget if needed (remove from the end — structural is lowest priority)
    if ($assembled.Length -gt $maxChars) {
        $assembled = $assembled.Substring(0, $maxChars)
        $assembled += "`n... (context trimmed to token budget)"
    }

    return $assembled
}
