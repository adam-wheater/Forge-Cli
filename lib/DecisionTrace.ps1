$Global:DecisionTraceFile = ""
$Global:DecisionTraceEvents = @()

function Initialize-DecisionTrace {
    [CmdletBinding()]
    param (
        [string]$OutputPath = ""
    )

    $Global:DecisionTraceEvents = @()

    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $logsDir = Join-Path $PSScriptRoot ".." "logs"
        if (-not (Test-Path $logsDir)) {
            New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
        }
        $ts = Get-Date -Format "yyyyMMdd-HHmmss"
        $OutputPath = Join-Path $logsDir "decision-trace-$ts.jsonl"
    }

    # Ensure parent directory exists
    $dir = Split-Path $OutputPath -Parent
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $Global:DecisionTraceFile = $OutputPath

    Write-Host "Decision trace initialized: $OutputPath"
}

function Trace-AgentDecision {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$Agent,
        [Parameter(Mandatory)][string]$Action,
        [string]$Tool = "",
        [string]$Input = "",
        [string]$Output = "",
        [int]$Tokens = 0
    )

    $event = @{
        Timestamp  = (Get-Date).ToUniversalTime().ToString("o")
        Agent      = $Agent
        Action     = $Action
        Tool       = $Tool
        Input      = $Input
        Output     = $Output
        TokensUsed = $Tokens
    }

    $Global:DecisionTraceEvents += $event

    # Append to JSONL file for streaming writes
    if ($Global:DecisionTraceFile) {
        try {
            $jsonLine = $event | ConvertTo-Json -Depth 10 -Compress
            $jsonLine | Out-File $Global:DecisionTraceFile -Encoding utf8 -Append
        } catch {
            Write-Warning "Failed to write decision trace event: $($_.Exception.Message)"
        }
    }
}

function Get-DecisionTrace {
    [CmdletBinding()]
    param (
        [string]$Agent = "",
        [int]$LastN = 0
    )

    $events = $Global:DecisionTraceEvents

    # Filter by agent if specified
    if ($Agent) {
        $events = $events | Where-Object { $_.Agent -eq $Agent }
    }

    # Limit to last N if specified
    if ($LastN -gt 0 -and $events.Count -gt $LastN) {
        $events = $events | Select-Object -Last $LastN
    }

    return $events
}

function Export-DecisionTrace {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateSet("json", "text")]
        [string]$Format
    )

    if (-not $Global:DecisionTraceEvents -or $Global:DecisionTraceEvents.Count -eq 0) {
        Write-Warning "No decision trace events to export."
        return ""
    }

    if ($Format -eq "json") {
        return ($Global:DecisionTraceEvents | ConvertTo-Json -Depth 10)
    }

    # Text format
    $lines = @()
    $lines += "=== Agent Decision Trace ==="
    $lines += "Events: $($Global:DecisionTraceEvents.Count)"
    $lines += ""

    foreach ($event in $Global:DecisionTraceEvents) {
        $toolStr = if ($event.Tool) { " [$($event.Tool)]" } else { "" }
        $tokenStr = if ($event.TokensUsed -gt 0) { " ($($event.TokensUsed) tokens)" } else { "" }

        $lines += "[$($event.Timestamp)] $($event.Agent): $($event.Action)$toolStr$tokenStr"

        if ($event.Input) {
            # Truncate long input for text display
            $inputPreview = if ($event.Input.Length -gt 200) { $event.Input.Substring(0, 200) + "..." } else { $event.Input }
            $lines += "  Input:  $inputPreview"
        }
        if ($event.Output) {
            # Truncate long output for text display
            $outputPreview = if ($event.Output.Length -gt 200) { $event.Output.Substring(0, 200) + "..." } else { $event.Output }
            $lines += "  Output: $outputPreview"
        }
        $lines += ""
    }

    return ($lines -join "`n")
}

function Get-DecisionSummary {
    [CmdletBinding()]
    param ()

    if (-not $Global:DecisionTraceEvents -or $Global:DecisionTraceEvents.Count -eq 0) {
        return "No decisions recorded."
    }

    # Group by agent
    $agentGroups = @{}
    foreach ($event in $Global:DecisionTraceEvents) {
        if (-not $agentGroups.ContainsKey($event.Agent)) {
            $agentGroups[$event.Agent] = @()
        }
        $agentGroups[$event.Agent] += $event
    }

    $summaryParts = @()

    foreach ($agent in $agentGroups.Keys) {
        $events = $agentGroups[$agent]
        $totalTokens = ($events | ForEach-Object { $_.TokensUsed } | Measure-Object -Sum).Sum

        # Count tool usage
        $toolCounts = @{}
        foreach ($e in $events) {
            if ($e.Tool) {
                if (-not $toolCounts.ContainsKey($e.Tool)) {
                    $toolCounts[$e.Tool] = 0
                }
                $toolCounts[$e.Tool]++
            }
        }

        $toolSummary = @()
        foreach ($tool in $toolCounts.Keys) {
            $count = $toolCounts[$tool]
            $toolSummary += "$count $tool"
        }

        $toolStr = if ($toolSummary.Count -gt 0) { " ($($toolSummary -join ', '))" } else { "" }

        # Look for significant actions
        $actions = $events | ForEach-Object { $_.Action } | Select-Object -Unique
        $actionSummary = @()
        foreach ($action in $actions) {
            $count = ($events | Where-Object { $_.Action -eq $action }).Count
            if ($count -gt 1) {
                $actionSummary += "$count x $action"
            } else {
                $actionSummary += $action
            }
        }

        $summaryParts += "$agent used $($events.Count) tool(s)$toolStr — actions: $($actionSummary -join ', ')"

        if ($totalTokens -gt 0) {
            $summaryParts[-1] += " — $($totalTokens.ToString('N0')) tokens"
        }
    }

    return ($summaryParts -join ". ")
}
